"""Items and orders in Postgres on RDS, or in memory when DB_HOST is unset (tests)."""
import itertools
import json
import logging
import random
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone

from . import config

log = logging.getLogger(__name__)

CATALOG_SIZE = 100
_ADVISORY_LOCK = 727  # serialises schema setup when many instances boot at once

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS items (
           id         BIGSERIAL PRIMARY KEY,
           name       TEXT NOT NULL,
           price      NUMERIC(12, 2) NOT NULL DEFAULT 0,
           stock      INTEGER NOT NULL DEFAULT 0,
           updated_at TIMESTAMPTZ NOT NULL DEFAULT now())""",
    """CREATE TABLE IF NOT EXISTS orders (
           id           BIGSERIAL PRIMARY KEY,
           item_id      BIGINT NOT NULL,
           quantity     INTEGER NOT NULL DEFAULT 1,
           request_type TEXT NOT NULL,
           created_at   TIMESTAMPTZ NOT NULL DEFAULT now())""",
    f"""INSERT INTO items (id, name, price, stock)
        SELECT g, 'item-' || g, round((1 + random() * 99)::numeric, 2), 100
        FROM generate_series(1, {CATALOG_SIZE}) AS g
        ON CONFLICT (id) DO NOTHING""",
    "SELECT setval(pg_get_serial_sequence('items', 'id'), GREATEST((SELECT max(id) FROM items), 1))",
]


class NotReady(Exception):
    """The database has not been reached yet; the API answers 503."""


def random_item_id():
    return random.randint(1, CATALOG_SIZE)


class MemoryStore:
    kind = "memory"

    def __init__(self):
        self._lock = threading.Lock()
        self._ids = itertools.count(CATALOG_SIZE + 1)
        self._order_ids = itertools.count(1)
        now = datetime.now(timezone.utc)
        self._items = {
            i: {"id": i, "name": f"item-{i}", "price": 10.0, "stock": 100, "updated_at": now}
            for i in range(1, CATALOG_SIZE + 1)
        }
        self._orders = {}
        self.ready = True

    def start(self):
        pass

    def list_items(self, limit, offset):
        with self._lock:
            return [self._items[k] for k in sorted(self._items)][offset:offset + limit]

    def get_item(self, item_id):
        with self._lock:
            return self._items.get(item_id)

    def create_item(self, name, price, stock):
        with self._lock:
            item_id = next(self._ids)
            item = {"id": item_id, "name": name, "price": price, "stock": stock,
                    "updated_at": datetime.now(timezone.utc)}
            self._items[item_id] = item
            return item

    def update_item(self, item_id, name=None, price=None, stock=None):
        with self._lock:
            item = self._items.get(item_id)
            if item is None:
                return None
            for key, value in (("name", name), ("price", price), ("stock", stock)):
                if value is not None:
                    item[key] = value
            item["updated_at"] = datetime.now(timezone.utc)
            return item

    def delete_item(self, item_id):
        with self._lock:
            return self._items.pop(item_id, None) is not None

    def create_order(self, item_id, quantity, request_type):
        with self._lock:
            order = {"id": next(self._order_ids), "item_id": item_id, "quantity": quantity,
                     "request_type": request_type, "created_at": datetime.now(timezone.utc)}
            self._orders[order["id"]] = order
            return order


class PostgresStore:
    kind = "postgres"

    def __init__(self):
        self._lock = threading.Lock()
        self._pool = None
        self.ready = False

    def start(self):
        """Connect and create the schema in the background; requests get 503 until then."""
        threading.Thread(target=self._connect_forever, name="db-init", daemon=True).start()

    def _connect_forever(self):
        delay = 2
        while not self.ready:
            try:
                self._pool = self._open_pool()
                with self._pool.connection() as conn:
                    conn.autocommit = True
                    conn.execute("SELECT pg_advisory_lock(%s)", (_ADVISORY_LOCK,))
                    try:
                        for statement in SCHEMA:
                            conn.execute(statement)
                    finally:
                        conn.execute("SELECT pg_advisory_unlock(%s)", (_ADVISORY_LOCK,))
                self.ready = True
                log.info("database ready at %s/%s", config.DB_HOST, config.DB_NAME)
            except Exception as exc:  # keep retrying: RDS may still be starting
                log.warning("database not ready (%s), retrying in %ss", exc, delay)
                time.sleep(delay)
                delay = min(delay * 2, 30)

    def _credentials(self):
        """RDS keeps {"username", "password"} in Secrets Manager and rotates it every 7 days."""
        if not config.DB_SECRET_ARN:
            return config.DB_USER, None
        import boto3

        client = boto3.client("secretsmanager", region_name=config.AWS_REGION)
        secret = json.loads(client.get_secret_value(SecretId=config.DB_SECRET_ARN)["SecretString"])
        return secret["username"], secret["password"]

    def _open_pool(self):
        from psycopg.rows import dict_row
        from psycopg_pool import ConnectionPool

        user, password = self._credentials()
        kwargs = {"host": config.DB_HOST, "port": config.DB_PORT, "dbname": config.DB_NAME, "user": user,
                  "sslmode": config.DB_SSLMODE, "connect_timeout": 5, "row_factory": dict_row}
        if password:
            kwargs["password"] = password
        pool = ConnectionPool(kwargs=kwargs, min_size=1, max_size=config.DB_POOL_MAX, timeout=10, open=False)
        pool.open(wait=True, timeout=30)
        return pool

    def _refresh(self, failed_pool):
        """After a connection failure, re-read the secret (it may have rotated) and swap the pool."""
        with self._lock:
            if self._pool is not failed_pool:
                return
            try:
                self._pool = self._open_pool()
            except Exception as exc:
                log.error("could not reopen the database pool: %s", exc)
                return
        failed_pool.close(timeout=5)

    @contextmanager
    def _conn(self):
        import psycopg
        from psycopg_pool import PoolTimeout

        if not self.ready:
            raise NotReady()
        pool = self._pool
        try:
            with pool.connection() as conn:
                yield conn
        except (psycopg.OperationalError, PoolTimeout):
            threading.Thread(target=self._refresh, args=(pool,), daemon=True).start()
            raise

    def list_items(self, limit, offset):
        with self._conn() as conn:
            return conn.execute(
                "SELECT id, name, price, stock, updated_at FROM items ORDER BY id LIMIT %s OFFSET %s",
                (limit, offset)).fetchall()

    def get_item(self, item_id):
        with self._conn() as conn:
            return conn.execute(
                "SELECT id, name, price, stock, updated_at FROM items WHERE id = %s", (item_id,)).fetchone()

    def create_item(self, name, price, stock):
        with self._conn() as conn:
            return conn.execute(
                "INSERT INTO items (name, price, stock) VALUES (%s, %s, %s) "
                "RETURNING id, name, price, stock, updated_at", (name, price, stock)).fetchone()

    def update_item(self, item_id, name=None, price=None, stock=None):
        with self._conn() as conn:
            return conn.execute(
                "UPDATE items SET name = COALESCE(%s, name), price = COALESCE(%s, price), "
                "stock = COALESCE(%s, stock), updated_at = now() WHERE id = %s "
                "RETURNING id, name, price, stock, updated_at", (name, price, stock, item_id)).fetchone()

    def delete_item(self, item_id):
        with self._conn() as conn:
            return conn.execute("DELETE FROM items WHERE id = %s RETURNING id", (item_id,)).fetchone() is not None

    def create_order(self, item_id, quantity, request_type):
        with self._conn() as conn:
            return conn.execute(
                "INSERT INTO orders (item_id, quantity, request_type) VALUES (%s, %s, %s) "
                "RETURNING id, item_id, quantity, request_type, created_at",
                (item_id, quantity, request_type)).fetchone()


STORE = PostgresStore() if config.DB_HOST else MemoryStore()
