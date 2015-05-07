name "controller_redhat"
description "Controller node on redhat"
run_list [
    "apt",
    "recipe[calico::control_redhat]"
]

