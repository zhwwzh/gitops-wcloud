variable "region" {
  type = string
}

variable "base_cidr" {
  type = string
  default = "172.16.0.0/12"
}

variable "sos_cidr" {
  type = string
  default = "192.168.12.128/26"
}

variable "sos_vpn_endpoint" {
  type = string
  default = "10.0.0.1"
}