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

# tfsec's no-public-ingress fires on any ingress from a public CIDR that
# is wider than a single host, so it will always fire here: students
# connect from public IPv6 space. The exposure is bounded instead by two
# validation blocks on var.rdp_allowed_prefixes, which reject ::/0 and
# 0.0.0.0/0 at PLAN time - a stronger guarantee than a lint rule.
resource "openstack_networking_secgroup_rule_v2" "rdp_in" {
  for_each       = toset(var.rdp_allowed_prefixes)
  direction      = "ingress"
  ethertype      = "IPv6"
  protocol       = "tcp"
  port_range_min = 3389
  port_range_max = 3389
  #tfsec:ignore:openstack-networking-no-public-ingress
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# ICMPv6 INGRESS. The egress counterpart below is not enough: IPv6
# Neighbour Discovery is a conversation. The VM sends Router and
# Neighbour Solicitations outbound, but the Router Advertisements and
# Neighbour Advertisements that answer them are unsolicited multicast
# from the router - not a stateful reply - so a security group drops
# them unless this rule exists. Without it the guest never installs an
# IPv6 default route, and RDP is unreachable even though the desktop
# configured itself perfectly. That cost a full deploy to find.
#
# fe80::/10 carries NDP itself; the DHBW prefix additionally allows
# ICMPv6 "Packet Too Big", without which large TCP segments black-hole
# instead of triggering path-MTU discovery.
resource "openstack_networking_secgroup_rule_v2" "icmpv6_in" {
  for_each          = toset(["fe80::/10", "2001:7c0:1b20::/48"])
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "ipv6-icmp"
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.win.id
}

# Egress allow-list. Ports chosen so Windows Update (80/443), DNS,
# NTP and KMS (1688) work while SSH/SMB/WinRM to neighbours do not.
#
# delete_default_rules removed the blanket allow-all, which means this
# list has to carry the NETWORK layer as well, not just applications.
# Leaving those out cost a full deploy: the guest never completed
# address configuration, so cloudbase-init could not reach the metadata
# service at 169.254.169.254, never fetched its user_data, and the VM
# came up with no user and no RDP - while Nova happily reported ACTIVE.
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
# PER-USER VMs
############################

resource "openstack_compute_instance_v2" "user_vm" {
  for_each = local.users_map

  # cloudbase-init turns the Nova name into the Windows hostname, which
  # is capped at 15 chars (NetBIOS) — a readable "win11-team-firstname"
  # would be silently truncated and could collide. Keep the name short
  # and unique; the human-readable identity lives in metadata below.
  name        = "${local.app_name}-${substr(md5(each.key), 0, 8)}"
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name

  # More reliable than the metadata service alone on a Windows guest.
  config_drive = true

  security_groups = [openstack_networking_secgroup_v2.win.name]

  timeouts {
    create = "30m"
    delete = "15m"
  }

  network {
    uuid = var.network_uuid
  }

  user_data = templatefile("${path.module}/bootstrap.ps1.tpl", {
    username    = each.value.username
    password    = random_password.user_passwords[each.key].result
    is_admin    = var.student_is_admin
    kms_host    = var.kms_host
    displayname = each.value.email
  })

  metadata = {
    team  = each.value.team
    app   = local.app_name
    user  = each.value.email
    login = each.value.username
  }
}

locals {
  # Nova reports both the NAT IPv4 and the public IPv6; students can only
  # reach the v6 one, so pick that explicitly rather than access_ip_v4.
  user_ipv6 = {
    for id, vm in openstack_compute_instance_v2.user_vm :
    id => try(
      [for n in vm.network : n.fixed_ip_v6 if n.fixed_ip_v6 != ""][0],
      vm.access_ip_v6
    )
  }

  # access_ip_v6 comes back bracketed from the provider while
  # fixed_ip_v6 does not. Normalise to a BARE address — the frontend and
  # the mail template both add brackets themselves.
  user_ipv6_bare = {
    for id, ip in local.user_ipv6 : id => replace(replace(ip, "[", ""), "]", "")
  }
}
