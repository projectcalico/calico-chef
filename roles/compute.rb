name "compute"
description "Compute nodes"
run_list [
    "apt",
    "recipe[calico::general_compute]"
]

