output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_id" { value = aws_subnet.public_a.id }
output "db_subnet_ids" { value = [aws_subnet.db_a.id, aws_subnet.db_c.id] }