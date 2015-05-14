name "controller_redhat"
description "Controller node on redhat"
run_list [
    "yum",
    "recipe[calico::control_redhat]"
]

