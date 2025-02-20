provider "aws" {
  region = "us-east-2"
}

# Define the VPC
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

# Create Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Main Internet Gateway"
  }
}

# Modify Public Subnet Route Table
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

# Associate Route Table with Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public.id
}

# Fetch Latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["137112412989"]  # Amazon Linux 2023 AMI owner ID
}

# Create Jenkins Security Group
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

# Create Additional EBS Volume
resource "aws_ebs_volume" "additional_volume" {
  availability_zone = aws_instance.jenkins_master.availability_zone
  size              = 8
  type              = "gp2"
}

# Attach Additional EBS Volume
resource "aws_volume_attachment" "attach_volume" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.additional_volume.id
  instance_id = aws_instance.jenkins_master.id
}

# Create Jenkins EC2 Instance
resource "aws_instance" "jenkins_master" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  key_name      = "new-aws-deploy-key"

  root_block_device {
    volume_size = 8
  }

  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y wget java-17-amazon-corretto-devel

              # Install Jenkins
              sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat/jenkins.repo
              sudo rpm --import https://pkg.jenkins.io/redhat/jenkins.io.key
              sudo yum --nogpgcheck install -y jenkins

              # Start Jenkins service
              sudo systemctl start jenkins
              sudo systemctl enable jenkins

              # Capture initial Jenkins admin password
              sudo cat /var/lib/jenkins/secrets/initialAdminPassword > /home/ec2-user/jenkins-admin-password
              sudo chmod 600 /home/ec2-user/jenkins-admin-password

              # Install AWS CLI (if not installed)
              sudo yum install -y aws-cli

              # Wait for Jenkins to be ready
              sleep 60

              # Install AWS EC2 and ECS plugins via Jenkins CLI
              JENKINS_URL="http://localhost:8080"
              ADMIN_PASSWORD=$(sudo cat /home/ec2-user/jenkins-admin-password)

              wget -O jenkins-cli.jar "$JENKINS_URL/jnlpJars/jenkins-cli.jar"
              java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:$ADMIN_PASSWORD install-plugin aws-ecs aws-java-sdk-ec2
              java -jar jenkins-cli.jar -s "$JENKINS_URL" -auth admin:$ADMIN_PASSWORD restart
              EOF

  tags = {
    Name = "Jenkins Master"
  }

  depends_on = [aws_security_group.jenkins_sg, aws_internet_gateway.main]
}

# Allocate Elastic IP for Jenkins
resource "aws_eip" "jenkins_eip" {
  instance = aws_instance.jenkins_master.id
}

# Create ECS Cluster for Jenkins Agents
resource "aws_ecs_cluster" "jenkins_fargate_cluster" {
  name = "jenkins-fargate-cluster"
}

# Output Jenkins URL
output "jenkins_url" {
  value = "http://${aws_instance.jenkins_master.public_ip}:8080"
}

# Output ECS Cluster ARN
output "ecs_cluster_arn" {
  value = aws_ecs_cluster.jenkins_fargate_cluster.arn
}

