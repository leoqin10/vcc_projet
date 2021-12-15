# The DB instance
resource "aws_db_instance" "ct_acct" {
  name       = "amazon"
  identifier = "controller-accounting"

  engine              = "mysql"
  engine_version      = "5.7.19"
  instance_class      = "db.t2.micro"
  allocated_storage   = 10
  storage_encrypted   = false
  skip_final_snapshot = true

  username = "root"
  password = "p4ssw0rd"

  db_subnet_group_name   = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.controller_ssh.id]
  availability_zone      = aws_subnet.a.availability_zone
}

resource "aws_db_subnet_group" "default" {
  name       = "sub-db-default"
  subnet_ids = [aws_subnet.a.id, aws_subnet.b.id]
}
