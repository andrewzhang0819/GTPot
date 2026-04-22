# GTPot
Automatic Cloud-Native Honeypot and Threat Intelligence Gathering Platform. 

GTPot is a cloud based honeypot with a centralized logging platform for observing and analyzing real world cyberattacks. This system utilizes cloud infrastructure, automation tools, and open-source security software to collect, process, and visualize attacker behavior in a controlled environment. Due to the project heavily relying on open-source software as well as the AWS Free Tier, the resulting cost of running the project is $16.78/month.

Features:
- Deploys AWS Architecture with two EC2 instances with Cowrie and Dionaea
- Deploys local ELK stack for live data analysis with a dashboard
- Dashboard with Analyst and Executive View
- Analyst: Logs, Behavioral Clustering, Attack Progression, Spatial Density, Temporal Density, Classification
- Executive: Spatial Density, Temporal Density, Summarized Report, Threat Score, Actions to Take

# Prerequisites
## Git Clone This Repostiory
https://github.com/andrewzhang0819/CloudPot.git

## Install Terraform
https://developer.hashicorp.com/terraform/install

## Install Ansible
https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html

## Install Docker
https://docs.docker.com/desktop/

## Create an AWS Account and Create an Acesss Key
1. Create an AWS account: https://signin.aws.amazon.com/signup?request_type=register
2. In the search bar, search for IAM, and go to the IAM dashboard
3. Click on "Users"
4. Click on "Create user" on the top right of the dashboard
5. Input any name you want
6. Click next
7. Click "Attach policies directly" 
8. Find the policy named "AdministratorAccess" and select it
9. Click next
10. Click "Create user"
11. Go back to the Users dashboard and click on your user
12. Click on "Security Credentials"
13. Click "Create access key"
14. Select "Local code" and the "Confirmation" at the bottom
15. Click next
16. Add a descripton
17. Click "Create access key"
18. Save the "Access key" and "Secret access key" as you will no longer have access to this after moving from this page
19. Click "Done"

## Install AWS CLI
https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

## Configure AWS CLI
https://docs.aws.amazon.com/cli/latest/userguide/cli-authentication-user.html
1. Type in the terminal "aws configure"
2. It will ask for the "AWS Access Key ID", input the "Access key" you saved earlier
3. Once entered, it will ask for the "AWS Secret Access Key" input the "Secret access key" you saved earlier
4. Once entered, it will ask for "Default region name", input "us-east-1" (for Georgia)
5. Once entered, it will ask for "Default output format", input "json"

# Running the Project
1. Place this repository in your $HOME directory (e.g. Users/andrew/CloudPot/)
2. Follow the commands to run the shell script
3. You will be presented with an link to your dashboard as well as the IP address of the Honeypot
4. To view your dashboard, go to the presented link; to view your AWS environment, go to the AWS console. 

## To Run The Shell Script
1. ```chmod +x deploy.sh```
2. ```./deploy.sh```

## To Stop Deployment, Run
1. ```terraform destroy```
2. ```cd elk && docker compose down -v```