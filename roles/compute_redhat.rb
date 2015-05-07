name "compute_redhat"
description "Compute nodes on Redhat"
run_list [
    "apt",
    "recipe[calico::general_compute_redhat]"
]

