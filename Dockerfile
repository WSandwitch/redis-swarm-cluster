FROM redis:7-alpine

COPY entrypoint.sh /start.sh
COPY boot.sh /boot.sh
CMD ["sh","/start.sh"]
