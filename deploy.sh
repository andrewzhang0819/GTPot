#!/bin/bash
# ^ shebang - allows for an executable shell script

##############################################################################################################
# Check for Dependencies: terraform, ansible, docker, aws cli

# Check Terraform Install
if ! command -v terraform >/dev/null 2>&1
then 
    echo "Terraform cannot be found. Please install Terraform and try again."
    exit 1
fi 

# Check Ansible Install
if ! command -v ansible >/dev/null 2>&1; then
    echo "Ansible cannot be found. Please install Ansible and try again."
    exit 1
fi

#Check Docker Install and Docker is actively running
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker cannot be found. Please install Docker and try again."
    exit 1
fi
 
if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running. Please start Docker and try again."
    exit 1
fi

# Check AWS CLI Install and AWS CLI configured with secret key
if ! command -v aws >/dev/null 2>&1; then
    echo "AWS CLI cannot be found. Please install AWS CLI and try again."
    exit 1
fi
 
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "AWS CLI is not configured. Please run 'aws configure' and try again."
    exit 1
fi

# Check to see if SSH key pair already exists, if it does, skip, else, generate key pair
FILE="$HOME/.ssh/id_rsa"
if [ -f "$FILE" ]; then
    echo "SSH key pair already exists... skipping"
else
    echo "SSH key pair not found... generating"
    ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
fi

# sanity check again, if the key pair was generated
if [ -f "$FILE" ]; then
    echo "$FILE exists... proceeding"
else
    echo "$FILE does not exist... exiting"
    exit 1
fi

##############################################################################################################
# Deployment
# Deploy Terraform
terraform init
terraform validate
terraform plan
terraform apply -auto-approve

# wait until terraform finishes and send output information to variables.env (IP address and SQS URL) for ansible and docker
COWRIE_IP=$(terraform output -raw cowrie_ip)
DIONAEA_IP=$(terraform output -raw dionaea_ip)
SQS_URL=$(terraform output -raw sqs_queue_url)
 
# sed -i "s|^COWRIE_IP=.*|COWRIE_IP=$COWRIE_IP|" variables.env
# sed -i "s|^SQS_URL=.*|SQS_URL=$SQS_URL|" variables.env
 
echo "SQS URL: $SQS_URL"
echo "COWRIE IP: $COWRIE_IP"
echo "DIONAEA_IP: $DIONAEA_IP"

QUEUE_NAME=$(echo $SQS_URL | awk -F'/' '{print $NF}')
AWS_REGION=$(echo $SQS_URL | awk -F'.' '{print $2}')
echo "Queue Name: $QUEUE_NAME"
echo "AWS Region: $AWS_REGION"

AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)

cat <<EOF > elk/variables.env
SQS_QUEUE_NAME=$QUEUE_NAME
AWS_REGION=$AWS_REGION
EC2_IP=$EC2_IP
SQS_URL=$SQS_URL
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
EOF
echo "Generated elk/variables.env with SQS and AWS credentials"

# wait until ec2 instance is ready on port 20022
echo "Waiting for Cowrie EC2 instance to be ready..."
until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$HOME/.ssh/id_rsa" -p 20022 ubuntu@"$COWRIE_IP" "exit" >/dev/null 2>&1; do
    echo "EC2 instance not ready yet... retrying in 10 seconds"
    sleep 10
done
echo "Cowrie EC2 instance is ready... proceeding"

echo "Waiting for Dionaea EC2 instance to be ready..."
until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$HOME/.ssh/id_rsa" -p 22 ubuntu@"$DIONAEA_IP" "exit" >/dev/null 2>&1; do
    echo "Dionaea EC2 instance not ready yet... retrying in 10 seconds"
    sleep 10
done
echo "Dionaea EC2 instance is ready... proceeding"

# dynamically create inventory.ini file for ansible
cat <<EOF > ansible/inventory.ini
[Cowrie]
$COWRIE_IP

[Cowrie:vars]
ansible_port=20022
ansible_user=ubuntu
ansible_ssh_private_key_file=$HOME/.ssh/id_rsa

[Dionaea]
$DIONAEA_IP

[Dionaea:vars]
ansible_port=22
ansible_user=ubuntu
ansible_ssh_private_key_file=$HOME/.ssh/id_rsa
EOF

# Install ansible community.docker module
ansible-galaxy collection install community.docker
    
# Deploy Ansible: download dependencies, download Cowrie, start Cowrie, download Python script, start Python script
ansible-playbook -i ansible/inventory.ini ansible/site.yml --private-key "$HOME/.ssh/id_rsa" --extra-vars "sqs_url=$SQS_URL"

# Start ELK stack
echo "Starting local ELK stack..."
cd elk && docker compose up -d
cd ..
echo "Waiting for ELK stack to be ready..."
sleep 180
# echo "Opening GTPot dashboard launcher..."
# cmd.exe /c start http://localhost:8080

# Output Kibana link
echo "Deployment complete. Access your Kibana dashboard at: http://localhost:8080"
