terraform {
  # Connection string comes from PG_CONN_STR, state encryption config from TF_ENCRYPTION.
  backend "pg" {
    schema_name = "intra"
  }
}
