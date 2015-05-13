name "controller_redhat"
description "Controller node on redhat"
run_list [
    "recipe[calico::control_redhat]"
]

