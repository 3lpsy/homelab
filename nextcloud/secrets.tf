# Generate random passwords
resource "random_password" "nextcloud_admin" {
  length  = 32
  special = true
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false
}

resource "random_password" "redis_password" {
  length  = 32
  special = false
}

resource "random_password" "collabora_password" {
  length  = 32
  special = false
}

# Generate HaRP shared key
resource "random_password" "harp_shared_key" {
  length  = 32
  special = false
}
