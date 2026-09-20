############################
# OUTPUT CONTRACT
############################

# ``authtype = "rdp"`` is the presentation hint the AppStore uses to
# render an mstsc connect string instead of an http:// link. Without it
# the frontend would build "http://<ip>:3389" from ip+port — a dead link,
# because RDP is not HTTP and because a bare IPv6 literal is not a valid
# URL authority. ``type`` stays "password": the credential really is one.
output "user_accounts" {
  description = "Per-user RDP credentials (one VM per user)"
  sensitive   = true
  value = {
    for id, user in local.users_map : id => {
      username = user.username
      type     = "password"
      authtype = "rdp"
      auth     = random_password.user_passwords[id].result
      ip       = local.user_ipv6_bare[id]
      port     = 3389
      email    = user.email
      team     = user.team
    }
  }
}

# Keyed by TEAM, as the infra panel expects. Deliberately carries no
# ``url`` key: this app has no web UI, and a ``url`` here would be
# rendered as the team's access link.
output "team_vms" {
  description = "Windows desktops grouped by team"
  value = {
    for team in local.teams_list : team => {
      vm_count = length([for u in local.all_users : u if u.team == team])
      desktops = [
        for id, user in local.users_map : {
          username      = user.username
          email         = user.email
          instance_name = openstack_compute_instance_v2.user_vm[id].name
          rdp_endpoint  = "[${local.user_ipv6_bare[id]}]:3389"
        } if user.team == team
      ]
    }
  }
}

output "teams_summary" {
  description = "Uebersicht: Teams und User-Anzahl"
  value = {
    for team in local.teams_list :
    team => length([for u in local.all_users : u if u.team == team])
  }
}
