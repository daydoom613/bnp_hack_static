"""Runtime settings. Every name here is part of the contract with scripts/user_data.sh."""
import os


def _float(name, default):
    return float(os.environ.get(name, default))


# web    = On-Demand API hosts (Web ASG). Serves every request type.
# worker = mixed On-Demand/Spot hosts (Worker ASG). Consumes the SQS job queue and
#          also serves the API, so the Spot guard can be demonstrated through the ALB.
ROLE = os.environ.get("ROLE", "web")

AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")

# Database. DB_SECRET_ARN is the RDS-managed secret; the password is never in env or code.
# Without DB_HOST the app keeps data in memory (unit tests, quick local runs).
DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "finops")
DB_SECRET_ARN = os.environ.get("DB_SECRET_ARN", "")
DB_USER = os.environ.get("DB_USER", "finops_admin")  # only used when DB_SECRET_ARN is empty (docker-compose)
DB_SSLMODE = os.environ.get("DB_SSLMODE", "require")
DB_POOL_MAX = int(os.environ.get("DB_POOL_MAX", "4"))

# Non-critical background work goes here; empty = process it inline.
QUEUE_URL = os.environ.get("QUEUE_URL", "")
CONSUMER_THREADS = int(os.environ.get("CONSUMER_THREADS", "2"))

# data/service_priority.xlsx, baked into the image (sheet "Priority").
PRIORITY_FILE = os.environ.get("PRIORITY_FILE", "/srv/data/service_priority.xlsx")

# Simulated processing cost per request, so CPU (and therefore scaling) tracks load.
CRITICAL_WORK_MS = _float("CRITICAL_WORK_MS", 20)
NONCRITICAL_WORK_MS = _float("NONCRITICAL_WORK_MS", 5)
JOB_WORK_MS = _float("JOB_WORK_MS", 40)

# Force the instance life cycle off EC2 (tests / docker-compose): "spot" or "on-demand".
INSTANCE_LIFECYCLE = os.environ.get("INSTANCE_LIFECYCLE", "")
