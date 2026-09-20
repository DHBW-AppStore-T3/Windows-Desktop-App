############################
# BOOTSTRAP READINESS GATE
############################
#
# Nova reporting ACTIVE means the hypervisor started the guest. It does
# NOT mean Windows came up. A VM that wedges in its first-boot specialize
# pass stays ACTIVE forever, never runs cloudbase-init, and cannot be
# recovered by rebooting — and without this gate the deployment is
# reported as SUCCESSFUL, credentials are mailed out, and the first
# person to discover the problem is the student who cannot log in.
#
# This turns that silent failure into a failed apply. wait_for_bootstrap.py
# polls the Nova console log for the "@@BOOTSTRAP done" marker that
# bootstrap.ps1.tpl prints as its last act.
#
# It reads the console log rather than probing TCP 3389 for a concrete
# reason: the worker container that runs Terraform has no IPv6 route
# ("Network is unreachable"), and these VMs are IPv6-only. The console log
# goes over the OpenStack API, which the worker does reach, and it proves
# the whole bootstrap ran rather than just that something bound a port.

resource "null_resource" "bootstrap_complete" {
  for_each = local.users_map

  # Re-run whenever the VM is replaced. Keyed on the instance id rather
  # than on a timestamp so an unrelated apply does not re-wait.
  triggers = {
    instance_id = openstack_compute_instance_v2.user_vm[each.key].id
  }

  provisioner "local-exec" {
    interpreter = ["python3"]
    command     = "${path.module}/wait_for_bootstrap.py"

    # The OS_* credentials the worker already exports for Terraform are
    # inherited from the process environment; only the per-VM values are
    # passed explicitly.
    environment = {
      SERVER_ID             = openstack_compute_instance_v2.user_vm[each.key].id
      SERVER_LABEL          = each.value.email
      READY_TIMEOUT_SECONDS = tostring(var.bootstrap_timeout_minutes * 60)
    }
  }
}
