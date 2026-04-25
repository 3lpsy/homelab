{
  "name": "ntfy",
  "url": "${ntfy_url}",
  "method": "post",
  "skip_tls_verify": true,
  "template": "ntfy",
  "headers": {
    "Authorization": "Basic ${ntfy_basic_b64}",
    "Content-Type": "text/plain",
    "Title": "OpenObserve alert",
    "Priority": "${ntfy_priority}",
    "Tags": "openobserve,alert"
  }
}
