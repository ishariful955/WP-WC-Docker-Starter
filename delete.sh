#!/bin/bash

set -x
echo "Script started at $(date)"

docker-compose down

# clear woocommerce and wordpress installation
rm -rf start.log wp-admin/ wp-content/ wp-includes/ wp-admin/* wp-content/* wp-includes/* index.php wp-config.php license.txt readme.html wp-activate.php wp-blog-header.php wp-comments-post.php wp-config-sample.php wp-cron.php wp-links-opml.php wp-load.php wp-login.php wp-mail.php wp-settings.php wp-signup.php wp-trackback.php xmlrpc.php wp-index.php

echo "Deleted all of the WordPress and woocommerce."

echo "Script ended at $(date)"
sleep 2

