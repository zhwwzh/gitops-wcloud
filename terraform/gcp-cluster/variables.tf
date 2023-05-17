variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "node_pools" {
  type = map(any)
}

variable "object_stores" {
  type = map(any)
}

variable "base_cidr" {
  type = string
}

variable "region_number" {
  type = number
}

variable "domain_name" {
  type = string
}

variable "service_account_names" {
  type = set(string)
}

variable "master_ipv4_cidr_block" {
  type = string
}

variable "default_node_pool_type" {
  type    = string
  default = "e2-standard-4"
}