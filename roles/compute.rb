name "compute"
description "Compute nodes on Ubuntu"
run_list [
    "apt",
    "recipe[calico::general_compute]"
]

