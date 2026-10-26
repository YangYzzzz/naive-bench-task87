FROM microblog:baseline
USER root
COPY --chown=1000:1000 app app
COPY --chown=1000:1000 migrations migrations
COPY --chown=1000:1000 microblog.py config.py boot.sh ./
RUN chmod a+x boot.sh && flask translate compile
USER 1000
ENV FLASK_APP=microblog.py
EXPOSE 5000
ENTRYPOINT ["./boot.sh"]
