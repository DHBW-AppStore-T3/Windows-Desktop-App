terraform {
  required_version = ">= 1.0"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
}

locals {
  app_name = "win11"
}

data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

############################
# USER MANAGEMENT (CONTRACT)
############################
#
# One VM PER USER — not per team. Windows 11 client permits exactly one
# interactive session at a time, so the shared-VM model the Linux apps
# use (Ubuntu-App: 30 SSH users on one box) cannot work here. The
# multi-session SKU is Azure-exclusive and Windows Server + RDS CALs are
# not covered by the university's A3 licensing.

locals {
  all_users = flatten([
    for team, members in var.users : [
      for member in members : {
        id    = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team  = team
        email = member.email
        # Windows local account names: max 20 chars and none of " / \ [ ] : ; | = , + * ? < >
        username = substr(replace(replace(split("@", member.email)[0], ".", ""), "-", ""), 0, 20)
      }
    ]
  ])

  users_map  = { for user in local.all_users : user.id => user }
  teams_list = distinct([for user in local.all_users : user.team])

  # The Nova instance name becomes the Windows NetBIOS name AND the name
  # on the RDP certificate, and it is what the student is told to type.
  # Derived once so those three can never disagree.
  vm_names = { for id in keys(local.users_map) : id => "${local.app_name}-${substr(md5(id), 0, 8)}" }
}

# One password per user. The character set deliberately excludes the
# single quote: the value is interpolated into a single-quoted PowerShell
# string in bootstrap.ps1.tpl, and a quote would terminate it early.
resource "random_password" "user_passwords" {
  for_each         = local.users_map
  length           = 20
  special          = true
  override_special = "!#%*_-+="
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

############################
# NETWORK / SECURITY
############################

# Own security group rather than a shared one, so the RDP rule is
# guaranteed to exist and is scoped. delete_default_rules drops the
# default allow-all egress; the explicit egress rules below are an
# allow-list, which is what stops a compromised student desktop from
# reaching SSH on the AppStore's own control-plane hosts (they sit in
# the same shared /48).
resource "openstack_networking_secgroup_v2" "win" {
  name                 = "${local.app_name}-desktops"
  description          = "Windows student desktops — RDP in, web/KMS/DNS out"
  delete_default_rules = true
}

# Trivy's OPNSTK-0003 fires on any ingress from a public CIDR wider than a
# single host, so it will always fire here: students connect from public
# IPv6 space. The exposure is bounded instead by two
# validation blocks on var.rdp_allowed_prefixes, which reject ::/0 and
# 0.0.0.0/0 at PLAN time - a stronger guarantee than a lint rule.
resource "openstack_networking_secgroup_rule_v2" "rdp_in" {
  for_each       = toset(var.rdp_allowed_prefixes)
  direction      = "ingress"
  ethertype      = "IPv6"
  protocol       = "tcp"
  port_range_min = 3389
  port_range_max = 3389
  #trivy:ignore:openstack-networking-no-public-ingress
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# ICMPv6 ingress, unscoped - deliberately.
#
# ICMPv6 is not a diagnostic nicety like IPv4 ping: it carries Neighbour
# Discovery and Router Advertisements, so filtering it stops IPv6 working
# altogether. Narrowing this to fe80::/10 plus the campus prefix was tried
# and left the guest holding only a link-local address, with every packet
# to its global address dropped before Windows saw it.
#
# RFC 4890 advises against filtering ICMPv6 wholesale for exactly this
# reason, and the working reference on this same network - the AppStore's
# own staging VM - does the same. The real exposure is TCP, and 3389 stays
# scoped to rdp_allowed_prefixes.
resource "openstack_networking_secgroup_rule_v2" "icmpv6_in" {
  direction = "ingress"
  ethertype = "IPv6"
  protocol  = "ipv6-icmp"
  #trivy:ignore:openstack-networking-no-public-ingress
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# DHCPv6 reply path. The client solicits from its link-local address to
# ff02::1:2 on port 547 (permitted by the egress list); the server answers
# from its own link-local to the client on port 546. Without this rule the
# reply is dropped and the guest solicits forever.
#
# Unscoped for the same reason as the ICMPv6 rule: a DHCPv6 client port is
# not meaningful attack surface, and a hand-derived "tighter" prefix has
# twice broken address configuration silently. 3389 stays scoped.
resource "openstack_networking_secgroup_rule_v2" "dhcpv6_in" {
  direction      = "ingress"
  ethertype      = "IPv6"
  protocol       = "udp"
  port_range_min = 546
  port_range_max = 546
  #trivy:ignore:openstack-networking-no-public-ingress
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# Egress allow-list. Ports chosen so Windows Update (80/443), DNS,
# NTP and KMS (1688) work while SSH/SMB/WinRM to neighbours do not.
#
# delete_default_rules removed the blanket allow-all, so this list has to
# carry the NETWORK layer too, not just applications. Without DHCP and NDP
# the guest never completes address configuration, cannot reach the
# metadata service at 169.254.169.254, and so never fetches its user_data -
# while Nova still reports ACTIVE.
locals {
  egress_tcp = [53, 80, 443, 1688]

  # 53 DNS, 123 NTP, plus DHCP. Without DHCP the guest has no address
  # and nothing above it works at all.
  egress_udp_v4 = [53, 123, 67, 68]
  egress_udp_v6 = [53, 123, 546, 547]
}

resource "openstack_networking_secgroup_rule_v2" "egress_tcp" {
  for_each          = toset([for p in local.egress_tcp : tostring(p)])
  direction         = "egress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  security_group_id = openstack_networking_secgroup_v2.win.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_udp" {
  for_each          = toset([for p in local.egress_udp_v6 : tostring(p)])
  direction         = "egress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# IPv4 egress too — the NAT subnet carries the metadata service and
# some update endpoints still resolve to A records.
# Neighbour Discovery. ICMPv6 is not a diagnostic nicety like ping over
# IPv4 - it is how IPv6 resolves link-layer addresses and finds its
# router. Without it the VM has no working IPv6 at all, and IPv6 is the
# only way a student can reach RDP on this cloud.
resource "openstack_networking_secgroup_rule_v2" "egress_icmpv6" {
  direction         = "egress"
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  security_group_id = openstack_networking_secgroup_v2.win.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_tcp_v4" {
  for_each          = toset([for p in local.egress_tcp : tostring(p)])
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  security_group_id = openstack_networking_secgroup_v2.win.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_udp_v4" {
  for_each          = toset([for p in local.egress_udp_v4 : tostring(p)])
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = tonumber(each.value)
  port_range_max    = tonumber(each.value)
  security_group_id = openstack_networking_secgroup_v2.win.id
}

############################
# PORTS
############################
#
# The port is created BEFORE the instance, so Terraform knows the address
# up front and can hand it to the guest in user_data. That breaks the
# dependency cycle an instance-derived address would create, and removes
# the dependence on DHCPv6 - which Windows does not complete on this
# dhcpv6-stateful subnet, leaving the guest with only a link-local
# address.

data "openstack_networking_subnet_v2" "v6" {
  network_id = var.network_uuid
  ip_version = 6
}

resource "openstack_networking_port_v2" "user_port" {
  for_each           = local.users_map
  network_id         = var.network_uuid
  security_group_ids = [openstack_networking_secgroup_v2.win.id]
}

locals {
  # all_fixed_ips carries both families; pick the v6 one.
  port_ipv6 = {
    for id, port in openstack_networking_port_v2.user_port :
    id => [for ip in port.all_fixed_ips : ip if length(regexall(":", ip)) > 0][0]
  }
}

############################
# PER-USER VMs
############################

resource "openstack_compute_instance_v2" "user_vm" {
  for_each = local.users_map

  # cloudbase-init turns the Nova name into the Windows hostname, which
  # is capped at 15 chars (NetBIOS) — a readable "win11-team-firstname"
  # would be silently truncated and could collide. Keep the name short
  # and unique; the human-readable identity lives in metadata below.
  name        = local.vm_names[each.key]
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name

  # More reliable than the metadata service alone on a Windows guest.
  config_drive = true

  # Security groups live on the port now, not on the instance.
  timeouts {
    create = "30m"
    delete = "15m"
  }

  network {
    port = openstack_networking_port_v2.user_port[each.key].id
  }

  user_data = templatefile("${path.module}/bootstrap.ps1.tpl", {
    username    = each.value.username
    password    = random_password.user_passwords[each.key].result
    is_admin    = var.student_is_admin
    kms_host    = var.kms_host
    displayname = each.value.email
    ipv6_addr   = local.port_ipv6[each.key]
    ipv6_prefix = split("/", data.openstack_networking_subnet_v2.v6.cidr)[1]
    ipv6_gw     = data.openstack_networking_subnet_v2.v6.gateway_ip
    vm_name     = local.vm_names[each.key]
  })

  metadata = {
    team  = each.value.team
    app   = local.app_name
    user  = each.value.email
    login = each.value.username
  }
}

locals {
  # Read from the port rather than the instance: it is the same address,
  # it is known earlier, and it is the one actually configured in the
  # guest. Bare, without brackets - the frontend and the mail template
  # each add their own.
  user_ipv6_bare = local.port_ipv6
}

