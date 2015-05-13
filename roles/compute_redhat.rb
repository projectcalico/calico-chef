name "compute_redhat"
description "Compute nodes on Redhat"
run_list [
    "recipe[calico::general_compute_redhat]"
]

