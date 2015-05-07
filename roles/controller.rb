name "controller"
description "controller node on ubuntu"
run_list [
    "apt",
    "recipe[calico::control]"
]

