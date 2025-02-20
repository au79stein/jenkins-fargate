provider "aws" {
  region = "us-east-2"
}

# Define the VPC (Virtual Private Cloud)
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "main_vpc"
  }
}

# Define the Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "Public Subnet"
  }
}

# Create the Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Main Internet Gateway"
  }
}

# Modify the public subnet route table to route traffic to the Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

# Associate the route table with the public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

# Fetch the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]  # Amazon Linux 2023 AMI naming pattern
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["137112412989"]  # AWS Amazon Linux 2023 AMI owner ID
}

# Create the Jenkins security group
resource "aws_security_group" "jenkins_sg" {
  name_prefix = "jenkins-sg-"
  description = "Allow SSH and HTTP(S) access"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Define the additional EBS volume
resource "aws_ebs_volume" "additional_volume" {
  availability_zone = aws_instance.jenkins_master.availability_zone
  size              = 8  # Size in GB
  type              = "gp2"
}

# Attach the additional EBS volume to the instance
resource "aws_volume_attachment" "attach_volume" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.additional_volume.id
  instance_id = aws_instance.jenkins_master.id
}

# Create the Jenkins instance
resource "aws_instance" "jenkins_master" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  key_name      = "new-aws-deploy-key"  # Replace with your SSH key pair name

  # Root block device configuration (for the root volume)
  root_block_device {
    volume_size = 8  # Increase size as needed (in GB)
  }

  # Security Group Association
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]

  # User data script for Jenkins setup
  user_data = <<-EOF
              #!/bin/bash
              # Update system and install dependencies
              sudo yum update -y
              sudo yum install -y wget

              # Install Amazon Corretto 17 JDK (preferred over OpenJDK)
              sudo yum install -y java-17-amazon-corretto-devel

              # Add the Jenkins repository (latest stable version)
              sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat/jenkins.repo
              # Install Jenkins
              sudo rpm --import https://pkg.jenkins.io/redhat/jenkins.io.key
              sudo yum --nogpgcheck install -y jenkins

              # Start Jenkins service
              sudo systemctl start jenkins
              sudo systemctl enable jenkins
              EOF

  # Tags and dependencies
  tags = {
    Name = "Jenkins Master"
  }

  depends_on = [aws_security_group.jenkins_sg, aws_internet_gateway.main]
}

# Allocate Elastic IP for the Jenkins instance
resource "aws_eip" "jenkins_eip" {
  instance = aws_instance.jenkins_master.id
}

# Output the Jenkins URL
output "jenkins_url" {
  value = "http://${aws_instance.jenkins_master.public_ip}:8080"
}

