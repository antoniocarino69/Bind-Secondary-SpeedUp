#BIND SECONDARY ZONE SPEED UP

After the problem with CrowdStrike a few weeks ago, several of my customers asked me if it was possible for DNS to work alongside other non-Windows DNS so that if a similar event occurred again, DNS resolution would continue to work.
Obviously the easiest thing for me to do was to implement a secondary copy of the desired zones in a BIND server.
After several requests and to speed up the time I decided to create this script. I hope it can help you too. It's in Italian now but I'll translate it into English as soon as I can.

#INSTRUCTIONS

Configure zone transfer on the master.
On the bind machine load this bash script.

chmod +x secondaryspeedup.sh


sudo ./secondaryspeedup.sh

Follow the script.

that's all!

Tested on OL9R4
