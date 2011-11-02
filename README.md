Riak Proxy Config
=================

Work in progress tool that contacts a running Riak cluster, queries the set
of nodes, and re-generates config files for various software proxies. This
allows users to add/remove nodes from the cluster using the standard
riak-admin approach and have the changes reflected in their proxy setup.

Currently, only setup for haproxy. Change base haproxy setup by modifying
the template at ``priv/haproxy.et``.

Update the ``app.config`` file after to with initial Riak seed nodes.
