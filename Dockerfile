FROM redis:7-alpine3.20

COPY entrypoint.sh /start.sh
COPY boot.sh /boot.sh
CMD ["sh","/start.sh"]
