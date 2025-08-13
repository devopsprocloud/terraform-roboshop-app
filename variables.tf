variable "project_name" {
    default = "roboshop"
}

variable "environment" {
    default = "dev"
}

variable "common_tags" {
    default = {
    Project = "roboshop"
    Environment = "dev"
    Terraform = "true"
  }
}

variable "tags" {

}

variable "zone_name" {
 

}

variable "vpc_id" {
  
}

variable "component_sg_id" {
  
}

variable "private_subnet_id" {
  
}

variable "iam_instance_profile" {
  
}

variable "private_subnet_ids" {
  
}

variable "rule_priority" {
  
}

variable "app_alb_listener_arn" {
  
}

variable "app_version" {
  
}