###########################################################################
# required terraform block to specify AWS provider
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "6.30.0" # always make sure version is up to date
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

###########################################################################
# specify the region and provider
provider "aws" {
    region = "us-east-1" # specify region for aws

    default_tags {
      tags = {
        Service     = "GTPot"
        Environment = "Dev"
      }
    }
}

###########################################################################
# define the vpc
resource "aws_vpc" "honeypot_vpc" {
    cidr_block = "10.0.0.0/16"
    instance_tenancy = "default" # multi-tenancy for cheaper costs
    enable_dns_support = true
    enable_dns_hostnames = true
    tags = {
        Name        = "HoneypotVPC"
        Service     = "GTPot"
        Environment = "Dev"
    }
}

###########################################################################
# Internet Gateway
resource "aws_internet_gateway" "honeypot_igw" {
    vpc_id = aws_vpc.honeypot_vpc.id

    tags = {
        Name = "HoneypotIGW"
        Service = "GTPot"
        Environment = "Dev"
    }
}

###########################################################################
# Route Table
resource "aws_route_table" "honeypot_rt" {
    vpc_id = aws_vpc.honeypot_vpc.id

    route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.honeypot_igw.id
    }
    tags = {
        Name = "HoneypotRT"
        Service = "GTPot"
        Environment = "Dev"
    }
    
    # this route is automatic
    # route {
    #   cidr_block = "10.0.0.0/16"
    #   gateway_id = "local"
    # }
}

###########################################################################
# define route table association with public subnet
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.honeypot_rt.id
}

###########################################################################
# data source for availability zone for public subnet
data "aws_availability_zones" "available" {
  state = "available"
}

# public subnet for honeypot traffic for isolation and preventing lateral movement
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.honeypot_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.honeypot_vpc.cidr_block, 8, 1) # should get a cidr_block of 10.0.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0] # pick best availability zone
  # map_public_ip_on_launch = true # instances launched in the subnet is assigned a public ip

  tags = {
    Name = "HoneypotPublicSubnet"
    Type = "Public"
    Service = "GTPot"
    Environment = "Dev"
  }
}

###########################################################################
# define the security groups
resource "aws_security_group" "cowrie_sg" {
    name = "cowrie-sg"
    description = "Allow traffic to cowrie"
    # format is [resource].[resource_name].id
    vpc_id = aws_vpc.honeypot_vpc.id # attach the security group to the vpc
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_security_group" "dionaea_sg" {
    name = "dionaea-sg"
    description = "Allow traffic to honeypot"
    # format is [resource].[resource_name].id
    vpc_id = aws_vpc.honeypot_vpc.id # attach the security group to the vpc
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define ingress rules for cowrie security group
#*************************************************************************#
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}
resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ansible" {
    security_group_id = aws_security_group.cowrie_sg.id
    cidr_ipv4 = "${chomp(data.http.my_ip.response_body)}/32"
    from_port = 20022
    to_port = 20022
    ip_protocol = "tcp"
    description = "Allow SSH for Ansible"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define ingress rules for cowrie honeypot
resource "aws_vpc_security_group_ingress_rule" "allow_ssh_cowrie" {
    security_group_id = aws_security_group.cowrie_sg.id
    cidr_ipv4 = "0.0.0.0/0" # allow any traffic
    from_port = 22
    to_port = 22 
    ip_protocol = "tcp"
    description = "Cowrie SSH Honeypot"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_telnet_cowrie" {
    security_group_id = aws_security_group.cowrie_sg.id
    cidr_ipv4 = "0.0.0.0/0" # allow any traffic
    from_port = 23
    to_port = 23
    ip_protocol = "tcp"
    description = "Cowrie Telnet Honeypot"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define egress rules to allow https outbound traffic for SQS communication
resource "aws_vpc_security_group_egress_rule" "allow_outbound_cowrie" {
    security_group_id = aws_security_group.cowrie_sg.id
    cidr_ipv4 = "0.0.0.0/0" # allow to all outbound ips
    from_port = 443 # HTTPS
    to_port = 443 # HTTPS
    ip_protocol = "tcp"
    description = "allow https outbound traffic for sqs"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define egress rules to allow http outbound traffic for apt updates
resource "aws_vpc_security_group_egress_rule" "allow_outbound_http_cowrie" {
  security_group_id = aws_security_group.cowrie_sg.id
  cidr_ipv4 = "0.0.0.0/0"
  from_port = 80
  to_port = 80
  ip_protocol = "tcp"
  description = "allow http outbound traffic for updates"
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define ingress rules for dionaea security group
#*************************************************************************#
resource "aws_vpc_security_group_ingress_rule" "allow_ssh_ansible_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "${chomp(data.http.my_ip.response_body)}/32"
    from_port = 22
    to_port = 22
    ip_protocol = "tcp"
    description = "Allow SSH for Ansible"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_ftp_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 21
    to_port = 21
    ip_protocol = "tcp"
    description = "Allow FTP"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_http_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 80
    to_port = 80
    ip_protocol = "tcp"
    description = "Allow HTTP"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_https_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 443
    to_port = 443
    ip_protocol = "tcp"
    description = "Allow HTTPS"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_smb_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 445
    to_port = 445
    ip_protocol = "tcp"
    description = "Allow SMB"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_mysql_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 3306
    to_port = 3306
    ip_protocol = "tcp"
    description = "Allow MySQL"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_sipudp_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 5060
    to_port = 5060
    ip_protocol = "udp"
    description = "Allow SIP"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_vpc_security_group_ingress_rule" "allow_siptcp_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    from_port = 5060
    to_port = 5060
    ip_protocol = "tcp"
    description = "Allow SIP"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define egress rules to allow https outbound traffic for SQS communication
resource "aws_vpc_security_group_egress_rule" "allow_outbound_dionaea" {
    security_group_id = aws_security_group.dionaea_sg.id
    cidr_ipv4 = "0.0.0.0/0" # allow to all outbound ips
    from_port = 443 # HTTPS
    to_port = 443 # HTTPS
    ip_protocol = "tcp"
    description = "Allow HTTPS outbound"
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

# define egress rules to allow http outbound traffic for apt updates
resource "aws_vpc_security_group_egress_rule" "allow_outbound_http_dionaea" {
  security_group_id = aws_security_group.dionaea_sg.id
  cidr_ipv4 = "0.0.0.0/0"
  from_port = 80
  to_port = 80
  ip_protocol = "tcp"
  description = "allow http outbound traffic for updates"
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}


###########################################################################
# data to get the most recent ubuntu version
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###########################################################################
# define ssh key pairfor access to ec2
# local computer must have this key pair to access ec2
resource "aws_key_pair" "honeypot_key" {
  key_name   = "honeypot-key"
  public_key = file("~/.ssh/id_rsa.pub") # generate key pair on your local computer
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
  # use ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
}

###########################################################################
# EC2 resouce
resource "aws_instance" "cowrie_hp" {
  # LAST UDPATE: Ubuntu, 24.04 - x86
  ami = data.aws_ami.ubuntu.id
  instance_type = "t3.micro" # probably chang to t3.small
  
  # public subnet
  subnet_id = aws_subnet.public_subnet.id
  # public ip
  associate_public_ip_address = true
  # security group
  vpc_security_group_ids = [aws_security_group.cowrie_sg.id]
  # access
  key_name = aws_key_pair.honeypot_key.key_name

  iam_instance_profile = aws_iam_instance_profile.attach_iam_to_ec2.name

  # set -e for error handling, create backup ssh_config file
  # remove previous port, echo new port, remove password authentication only ssh key pair
  # test the configuration, restart and apply configuration
  # sudo sed --in-place 's/^#\?Port 22$/Port 20022/g' /etc/ssh/sshd_config
  user_data = <<-EOF
              #!/bin/bash
              set -e 
              NEW_PORT=20022
              cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
              sudo sed -i '/^#\?Port /d' /etc/ssh/sshd_config
              echo "Port $NEW_PORT" >> /etc/ssh/sshd_config
              sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
              mkdir -p /run/sshd
              sshd -t
              sudo systemctl daemon-reload
              sudo service ssh restart
              EOF
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

resource "aws_instance" "dionaea_hp" {
    ami = data.aws_ami.ubuntu.id
    instance_type = "t3.micro"

    subnet_id = aws_subnet.public_subnet.id
    associate_public_ip_address = true
    vpc_security_group_ids = [aws_security_group.dionaea_sg.id]
    key_name = aws_key_pair.honeypot_key.key_name
    iam_instance_profile = aws_iam_instance_profile.attach_iam_to_ec2.name
    tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}

###########################################################################
# AWS SQS resource
resource "aws_sqs_queue" "honeypot_logs" {
  name                      = "log-queue"
  message_retention_seconds = 86400 # 1 Day
  receive_wait_time_seconds = 20
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}
resource "aws_sqs_queue_policy" "https_only" {
  queue_url = aws_sqs_queue.honeypot_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "HTTPSONLY"
    Statement = [{
      Sid       = "DenyUnsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = aws_sqs_queue.honeypot_logs.arn
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }]
  })
}

###########################################################################
# Define IAM Roles
# IAM role for EC2
resource "aws_iam_role" "ec2_iam_role" {
  name = "ec2_role"
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }

    ]
  })
}
# IAM policy for EC2 role
resource "aws_iam_role_policy" "allow_ec2_to_sqs_communication" {
  name = "allow_ec2_to_sqs"
  role = aws_iam_role.ec2_iam_role.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sqs:SendMessage"
        Effect = "Allow"
        Resource = aws_sqs_queue.honeypot_logs.arn
      }
    ]
  })
}
# Attach EC2 instance with EC2 role
resource "aws_iam_instance_profile" "attach_iam_to_ec2" {
  name = "ec2_iam_attachment"
  role = aws_iam_role.ec2_iam_role.name
  tags = {
        Service     = "GTPot"
        Environment = "Dev"
    }
}
###########################################################################
# output information
output "cowrie_ip" {
  value = aws_instance.cowrie_hp.public_ip
}
output "dionaea_ip" {
    value = aws_instance.dionaea_hp.public_ip
}
output "sqs_queue_url" {
  value = aws_sqs_queue.honeypot_logs.url
}