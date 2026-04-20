path "secret/data/ussd-kernel/*" {
  capabilities = ["read"]
}

path "secret/metadata/ussd-kernel/*" {
  capabilities = ["read", "list"]
}
