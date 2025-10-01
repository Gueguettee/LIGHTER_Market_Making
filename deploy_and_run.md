# AWS EC2 Docker Automation Script

This Bash script automates the deployment, execution, and retrieval of files on an AWS EC2 instance using Docker Compose. It can start an instance, install Docker, transfer code, build and run Docker containers, and retrieve results.

---

## Features

- Configure local machine with required tools (`jq`, `ssh`, `rsync`, `curl`).
- Configure AWS CLI using credentials from JSON files.
- Start and stop EC2 instances.
- Install Docker and Docker Compose (V2) on the instance.
- Transfer project files to the instance.
- Build Docker images and run containers.
- Retrieve logs, parameters, or other output files from the instance.

---

## Prerequisites

- **AWS Account** with EC2 access.
- **SSH key** for connecting to your instance.
- `bash`, `dos2unix` installed on your local machine.

---

## Project Structure

```text
.
├── deploy_and_run.sh                 # This script
├── secrets/
│   ├── aws_credentials.json  # AWS access keys
│   └── aws_instance.json     # EC2 instance ID & region
├── logs/                     # Retrieved logs (optional)
├── params/                   # Retrieved parameters (optional)
└── lighter_data/             # Retrieved data (optional)
```

## Setup

1. **Clone or place your project** locally.

2. **Create `secrets` folder** in your project root:

```bash
mkdir -p secrets
```

---

Create a folder called `secrets` in your project root, and add two files:

**`secrets/aws_credentials.json`**

```json
{
    "aws_access_key_id": "YOUR_AWS_ACCESS_KEY_ID",
    "aws_secret_access_key": "YOUR_AWS_SECRET_ACCESS_KEY"
}
```

**`secrets/aws_instance.json`**

```json
{
    "instance_id": "i-xxxxxxxxxxxxxxxxx",
    "region": "us-east-1"
}
```

Replace values with your actual AWS credentials and instance information.

---

### Usage

Only if on Windows:

```bash
dos2unix deploy_and_run.sh
```

If it's the first time you run the script, use the `install` argument to set up the instance:

```bash
./deploy_and_run.sh install
```

For subsequent runs, use the `run` argument to execute the Docker container in the foreground:

```bash
./deploy_and_run.sh run
```

If you want to start the container in detached mode, use the `startRun` argument.

```bash
./deploy_and_run.sh startRun
```

To stop the container and retrieve files, use the `stopRun` argument:

```bash
./deploy_and_run.sh stopRun
```

If you want to just connect to the instance via SSH, use the `connect` argument:

```bash
./deploy_and_run.sh connect
```
