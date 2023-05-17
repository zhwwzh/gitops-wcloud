variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "region_number" {
  type = number
}

variable "base_cidr" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "node_pools" {
  type = map(any)
}

variable "object_stores" {
  type = map(any)
}

variable "service_account_names" {
  type = set(string)
}