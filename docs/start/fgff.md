mtd3 git clone httpsudo install -d /opt/fakequasar
sudo cp -r copymetoroot/opt/fakequasar/certs /opt/fakequasar/
sudo install -d /etc/nginx/sites-enabled
sudo cp copymetoroot/etc/nginx/sites-enabled/quasar \
  /etc/nginx/sites-enabled/quasar
sudo nginx -t
sudo systemctl reload nginxs://git.gay/iwakura/eQuasar.git
cd eQuasardocker compose up -d --buildsudo tail -f /var/log/nginx/quasar.yandex.net.access.log