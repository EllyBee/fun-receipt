fun-receipt
===========


To install on a fresh PI.

sudo apt-get update
sudo apt-get upgrade
sudo apt-get install rubygems
sudo apt-get install ruby-cairo
sudo apt-get install ruby-dev
sudo apt-get install bundler

Copy over the funprinter directory and all contents to:
/home/pi/

Change into that directory
cd ~/funprinter

run bundle install to download all the required gems
sudo bundle install

Copy the init script to the init.d directory
sudo cp ~/funprinter/initScript/funprinter /etc/init.d/funprinter

Make that script executable
sudo chmod 775 /etc/init.d/funprinter

Make it run at startup
sudo update-rd.d funprinter defaults

either reboot, or start the fun printer
service funprinter start

to stop it
service funprinter stop

to check it’s running 
service funprinter status

to check the logs
tail -f /var/log/funprinter.log


---

Things still to fix
===================

1. it never deletes any local images. 
2. It will print as many times as you press the button. There is no way to tell when it's finished printing so the best that could be done would be to put in a timer eg. it won't accept another press for 1 second or something. 
