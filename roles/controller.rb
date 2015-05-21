name "controller"
description "controller node"
run_list [
    "apt",
    "recipe[calico::control]",
    "recipe[calico::horizon]",
    "recipe[calico::cinder]",
    "recipe[calico::neutron]",
    "recipe[calico::calico_control]",
    "recipe[calico::deployment_configuration]",
    "recipe[calico::live_migration]"
]

