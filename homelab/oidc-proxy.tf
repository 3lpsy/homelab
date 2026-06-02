# Public reverse proxy for the in-cluster Zitadel OIDC server. Lets
# off-tailnet browsers complete a headscale OIDC login without first
# joining the tailnet (the chicken-egg of OIDC-via-tailnet-only-issuer).
#
# Design:
#   - Same hostname as the in-cluster Zitadel TS sidecar
#     (`oidc.<magic_domain>`). Public Route53 A record points at the
#     headscale EC2; on-tailnet clients still resolve via MagicDNS to
#     the in-cluster TS IP. Issuer URL stays byte-identical so existing
#     OIDC consumers (grafana, audiobookshelf, homeassist, rustical)
#     don't need re-config.
#   - HTTP basic-auth gate at nginx as a low-friction front door (creds
#     from .env). Zitadel password / passkey is the real auth.
#   - Lives on the same nginx as headscale itself but in a separate
#     /etc/nginx/conf.d/ file; the base nginx.conf was extended to
#     include conf.d/*.conf so the two vhosts coexist without either
#     overwriting the other.
#   - Upstream resolved at request time via the resolver directive
#     pointing at MagicDNS (100.100.100.100) so the EC2 always reaches
#     the in-cluster TS IP, never loops back to its own public IP.

locals {
  oidc_proxy_fqdn = "${var.zitadel_subdomain}.${var.headscale_subdomain}.${var.headscale_magic_domain}"
}

# Public DNS — splits horizon: off-tailnet clients hit the EC2,
# on-tailnet clients still resolve to the in-cluster TS IP via MagicDNS.
resource "aws_route53_record" "oidc_proxy" {
  zone_id = module.headscale-infra-dns.magic_zone_id
  name    = local.oidc_proxy_fqdn
  type    = "A"
  ttl     = 60
  records = [module.headscale-infra.public_ip]
}

# ACME cert for the public hostname — DNS-01 via Route53, same flow as
# the headscale cert.
module "oidc_proxy_tls" {
  source                     = "./../templates/infra-tls"
  account_key_pem            = module.homelab-infra-tls.account_key_pem
  server_domain              = local.oidc_proxy_fqdn
  aws_region                 = var.aws_region
  aws_access_key             = var.aws_access_key
  aws_secret_key             = var.aws_secret_key
  recursive_nameservers      = var.recursive_nameservers

  depends_on = [aws_route53_record.oidc_proxy]
  providers = {
    acme = acme
  }
}

# Cert deploy to /etc/letsencrypt/live/<fqdn>/{fullchain,privkey}.pem.
module "oidc_proxy_provision_tls" {
  source            = "./../templates/provision-tls"
  server_ip         = module.headscale-infra.public_ip
  ssh_user          = module.headscale-infra.ssh_user
  ssh_priv_key      = trimspace(file(var.ssh_priv_key_path))
  domain            = local.oidc_proxy_fqdn
  tls_privkey_pem   = module.oidc_proxy_tls.privkey_pem
  tls_fullchain_pem = module.oidc_proxy_tls.fullchain_pem
}

# htpasswd seed — generated on the EC2 via apache2-utils' htpasswd so
# we get a stable bcrypt hash (TF's bcrypt() re-randomizes the salt on
# every plan, which would force an apply every run). Re-seeds only when
# user OR password changes via the trigger hash. The htpasswd file is
# owned by root:www-data 640 so nginx can read but other users can't.
resource "null_resource" "oidc_proxy_htpasswd" {
  triggers = {
    creds_hash = sha1("${var.oidc_proxy_user}:${var.oidc_proxy_password}")
  }

  connection {
    type        = "ssh"
    host        = module.headscale-infra.public_ip
    user        = module.headscale-infra.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "remote-exec" {
    inline = [
      # -B = bcrypt, -b = password from cmd-line, -c = create (first user
      # only — overwrites any prior content, intentional since we keep one
      # shared cred). htpasswd binary is provided by apache2-utils,
      # installed by headscale-provision-dep.
      "sudo htpasswd -bBc /etc/nginx/oidc-public.htpasswd ${var.oidc_proxy_user} '${replace(var.oidc_proxy_password, "'", "'\\''")}'",
      "sudo chown root:www-data /etc/nginx/oidc-public.htpasswd",
      "sudo chmod 640 /etc/nginx/oidc-public.htpasswd",
    ]
  }

  depends_on = [module.headscale-provision-dep]
}

# Vhost file. Drops into /etc/nginx/conf.d/ which the base nginx.conf
# now includes. Reload nginx on any content change (safer than restart;
# headscale's vhost stays up).
resource "null_resource" "oidc_proxy_vhost" {
  triggers = {
    config = md5(templatefile("${path.root}/../data/nginx/oidc-public.nginx.conf.tpl", {
      oidc_fqdn = local.oidc_proxy_fqdn
    }))
  }

  connection {
    type        = "ssh"
    host        = module.headscale-infra.public_ip
    user        = module.headscale-infra.ssh_user
    private_key = trimspace(file(var.ssh_priv_key_path))
    timeout     = "1m"
  }

  provisioner "file" {
    content = templatefile("${path.root}/../data/nginx/oidc-public.nginx.conf.tpl", {
      oidc_fqdn = local.oidc_proxy_fqdn
    })
    destination = "/home/${module.headscale-infra.ssh_user}/oidc-public.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/${module.headscale-infra.ssh_user}/oidc-public.conf /etc/nginx/conf.d/oidc-public.conf",
      "sudo chown root:www-data /etc/nginx/conf.d/oidc-public.conf",
      "sudo chmod 644 /etc/nginx/conf.d/oidc-public.conf",
      "sudo nginx -t",
      "sudo systemctl reload nginx",
    ]
  }

  depends_on = [
    module.headscale-provision-nginx,
    module.oidc_proxy_provision_tls,
    null_resource.oidc_proxy_htpasswd,
  ]
}
