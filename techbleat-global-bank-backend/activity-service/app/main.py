import json
import logging
import os
import threading
import time

from confluent_kafka import Consumer
from fastapi import Depends, FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import create_engine, text

from app.auth import Caller, deny, require_roles

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("activity-service")

DATABASE_URL = os.getenv("DATABASE_URL")
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:29092")
FRONTEND_ORIGIN = os.getenv("FRONTEND_ORIGIN", "http://localhost:3000")
KAFKA_GROUP_ID = os.getenv("KAFKA_GROUP_ID", "activity-service-group")
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "banking-transactions")

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is required")

engine = create_engine(f"postgresql+psycopg2://{DATABASE_URL.split('://', 1)[1]}")

app = FastAPI(title="Techbleat Global Bank - Activity Service")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[FRONTEND_ORIGIN],
    allow_methods=["GET"],
    allow_headers=["Authorization", "Content-Type"],
)


def kafka_config():
    config = {
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "group.id": KAFKA_GROUP_ID,
        "auto.offset.reset": "earliest",
    }
    # Mutual TLS to the in-cluster Kafka (Strimzi): cluster CA plus this service's client
    # certificate. Unset locally, where Compose Kafka is plaintext.
    if os.getenv("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT").upper() == "SSL":
        config.update(
            {
                "security.protocol": "SSL",
                "ssl.ca.location": os.environ["KAFKA_SSL_CA_LOCATION"],
                "ssl.certificate.location": os.environ["KAFKA_SSL_CERTIFICATE_LOCATION"],
                "ssl.key.location": os.environ["KAFKA_SSL_KEY_LOCATION"],
            }
        )
    return config


def kafka_consumer_loop():
    consumer = None
    while consumer is None:
        try:
            consumer = Consumer(kafka_config())
            consumer.subscribe([KAFKA_TOPIC])
        except Exception as error:
            logger.warning("kafka_consumer_start_failed error=%s", type(error).__name__)
            time.sleep(3)

    while True:
         try:
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                logger.warning("kafka_message_error error=%s", msg.error())
                continue

            event = json.loads(msg.value().decode("utf-8"))
            user_id = event.get("userId", "unknown")
            activity_type = event.get("eventType", "UNKNOWN")
            amount = event.get("amount", 0)
            description = f"{activity_type} of {amount} by {user_id}"

            with engine.begin() as conn:
                conn.execute(
                    text(
                        '''
                        INSERT INTO activities (user_id, activity_type, description)
                        VALUES (:user_id, :activity_type, :description)
                        '''
                    ),
                    {
                        "user_id": user_id,
                        "activity_type": activity_type,
                        "description": description,
                    },
                )
         except Exception as error:
            # Log the failure type only: event payloads contain account and amount data.
            logger.error("activity_event_failed error=%s", type(error).__name__)
            time.sleep(1)


@app.on_event("startup")
def startup_event():
    thread = threading.Thread(target=kafka_consumer_loop, daemon=True)
    thread.start()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/activities/{user_id}")
def get_activities(user_id: str, request: Request, caller: Caller = Depends(require_roles("banking-customer"))):
    if user_id != caller.user_id:
        raise deny(request, caller, "activity history belongs to another user")
    with engine.begin() as conn:
        rows = conn.execute(
            text(
                '''
                SELECT id, user_id, activity_type, description, created_at
                FROM activities
                WHERE user_id = :user_id
                ORDER BY created_at DESC
                LIMIT 20
                '''
            ),
            {"user_id": user_id},
        ).mappings().all()
        return [dict(row) for row in rows]
