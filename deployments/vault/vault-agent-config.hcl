auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/vault/role-id"
      secret_id_file_path = "/vault/secret-id"
    }
  }

  sink "file" {
    config = {
      path = "/vault/.vault-token"
    }
  }
}

template {
  destination = "/secrets/ecocash-credentials.json"
  contents    = <<EOT
{{ with secret "secret/data/ussd-kernel/providers/ecocash" }}
{
  "base_url": "{{ .Data.data.base_url }}",
  "merchant_id": "{{ .Data.data.merchant_id }}",
  "api_key": "{{ .Data.data.api_key }}",
  "secret_key": "{{ .Data.data.secret_key }}"
}
{{ end }}
EOT
}

template {
  destination = "/secrets/postgres-url"
  contents    = <<EOT
{{ with secret "secret/data/ussd-kernel/database" }}
postgres://{{ .Data.data.user }}:{{ .Data.data.password }}@{{ .Data.data.host }}:{{ .Data.data.port }}/{{ .Data.data.database }}?sslmode=require
{{ end }}
EOT
}

vault {
  address = "https://vault.example.com:8200"
}
