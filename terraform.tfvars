aws_region      = "us-east-1"
project_name    = "sre-process-service"
environment     = "dev"
api_rate_limit  = 20
api_burst_limit = 10
redis_node_type = "cache.t3.micro"

# --- EC2 / ALB / ASG ---
ec2_instance_type    = "t3.micro"
asg_min_size         = 1
asg_max_size         = 4
asg_desired_capacity = 2

# --- RDS ---
db_engine                = "postgres"
db_engine_version        = "16.3"
db_instance_class        = "db.t3.micro"
db_allocated_storage     = 20
db_max_allocated_storage = 100
db_name                  = "appdb"
db_username              = "dbadmin"
# db_password            = ""  # NO hardcodear aquí — pasar como: export TF_VAR_db_password="..."
db_multi_az              = false
db_backup_retention_days = 7

# --- AWS Backup ---
backup_retention_days    = 14
backup_cold_storage_days = 30

# --- Grafana ---
grafana_instance_type = "t3.small"
# grafana_admin_password = ""  # Pasar como: export TF_VAR_grafana_admin_password="..."
