COPY src/start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]