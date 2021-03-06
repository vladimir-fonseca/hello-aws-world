# Create a VPC
resource "aws_vpc" "web" {
  cidr_block = var.vpc_cidr

  tags = merge(
    local.tags,
    {
      Name = "web-vpc"
    })

  depends_on = []

}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.web.id

  tags = merge(
    local.tags,
    {
      Name = "vpc_igw"
    })

  depends_on = [
    aws_vpc.web,
  ]
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.web.id
  cidr_block              = var.public_subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = var.availability_zone

  tags = merge(
    local.tags,
    {
      Name = "public-subnet"
    })

  depends_on = [
    aws_vpc.web,
  ]
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.web.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(
    local.tags,
    {
      Name = "public-route_table"
    })

  depends_on = [
    aws_vpc.web,
    aws_internet_gateway.igw,
  ]
}

resource "aws_route_table_association" "public_rt_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "sg_web" {
  name        = "allow_ssh_http"
  description = "Allow ssh and http inbound traffic"
  vpc_id      = aws_vpc.web.id

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [
      var.my_ip_address,
    ]
  }

  ingress {
    description      = "Allow HTTP from VPC"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(
    local.tags,
    {
      Name = "allow_ssh_http"
    })

  depends_on = [
    aws_vpc.web,
    aws_internet_gateway.igw,
    aws_route_table_association.public_rt_association
  ]
}

resource "tls_private_key" "ssh" {
  count = var.generate_ssh_key ? 1: 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  count = var.generate_ssh_key ? 1: 0

  key_name   = var.ssh_key_name
  public_key = tls_private_key.ssh[count.index].public_key_openssh
}

resource "local_file" "pem_file" {
  count = var.generate_ssh_key ? 1: 0

  filename              = pathexpand("~/.ssh/${var.ssh_key_name}.pem")
  file_permission       = "600"
  directory_permission  = "700"
  sensitive_content     = tls_private_key.ssh[count.index].private_key_pem
}


resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name

  subnet_id = aws_subnet.public_subnet.id
  security_groups = [
    aws_security_group.sg_web.id
  ]

  root_block_device {
    volume_size           = var.root_device.size
    volume_type           = var.root_device.type
    delete_on_termination = var.root_device.delete_on_termination
  }

  ebs_block_device {
    device_name           = var.ebs_device.name
    volume_size           = var.ebs_device.size
    volume_type           = var.ebs_device.type
    delete_on_termination = var.ebs_device.delete_on_termination
  }

  user_data_base64            = data.template_cloudinit_config.web.rendered
  iam_instance_profile         = aws_iam_instance_profile.web.name
  associate_public_ip_address = "false"

  tags = merge(
    local.tags,
    {
      Name = "web-server"
    })

  volume_tags =  merge(
    local.tags,
    {
      Name = "web-server"
    })

  depends_on = [
    aws_vpc.web,
    aws_internet_gateway.igw,
    aws_route_table_association.public_rt_association,
    aws_security_group.sg_web,
    aws_key_pair.generated_key
  ]
}

resource "aws_eip" "web" {
  instance = aws_instance.web.id
  vpc      = true
  
  tags = merge(
    local.tags,
    {
      Name = "eip-web-server"
    })

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.web.id
  allocation_id = aws_eip.web.id
}

resource "aws_iam_role" "web" {
  name_prefix           = "role-web-server"
  path                 = "/"
  assume_role_policy   = data.aws_iam_policy_document.web.json
}

resource "aws_iam_role_policy_attachment" "web_AmazonSSMManagedInstanceCore" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "web_AmazonEC2RoleforSSM" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_instance_profile" "web" {
  name_prefix  = "profile-web-server"
  role        = join("", aws_iam_role.web.*.name)
}