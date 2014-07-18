Calico Chef
===========

This repository contains Chef cookbooks and roles for installing Project
Calico-enabled OpenStack deployments.

The cookbooks in this repository install a very specific type of OpenStack
deployment. They provide very few configuration options, making them simple to
work with and easy to get started with quickly. However, they are ill-suited to
production OpenStack deployments.

Using These Cookbooks
---------------------

The repository contains one recipe for control nodes and one recipe for compute
nodes, as well as one role for each. To install an OpenStack deployment from
these cookbooks, install one machine with the `controller` role and at least
one machine with the `compute` role. When install is complete, you should be
ready to go.

Known Limitations
-----------------

If installing machines sequentially using `knife bootstrap` the Chef server can
take a while to spot recently bootstrapped machines and to sort them into their
roles. This can cause problems when installing nodes with the `compute` role,
as they rely on having up-to-date knowledge of all other `compute` nodes. If
you encounter problems, try waiting thirty seconds before attempting the
install again.

Note also that it is not expected that you can install a single machine with
both `controller` and `compute` roles. This _may_ work, but is not supported.

License
-------

These cookbooks are published under the Apache 2.0 License. See `LICENSE` for
more details.
