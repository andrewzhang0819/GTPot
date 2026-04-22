# script to parse json logs from cowrie honeypot to aws sqs
# TO CONSIDER: If there are multiple EC2 instances, provide a socket id for the log to have an attached "which ec2 instance" id
import boto3
import json
import os
import time
import logging # better debugging messages
import uuid

MAX_SQS_MESSAGE_SIZE = 256 * 1024  # 256KB

QUEUE_URL = os.environ.get("SQS_URL", "") # tries to get the environment variable for the sqs url
LOG_PATH = os.environ.get("HONEYPOT_LOG_PATH", "") # gets the cowrie log path
SENSOR_ID = os.environ.get("HONEYPOT_TYPE", "") # gets the type of honeypot of either dionaea or cowrie
AWS_REGION = "us-east-1"
BATCH_SIZE = int(10) # batch size for how many messages to send per batch (max size is only 10)
FLUSH_INTERVAL = int(20)  # seconds before forcing a flush 

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s") # logging format
log = logging.getLogger(__name__)

# Continually checks the tail of cowrie.json and yields any new logs
def tail_file(path):
    # Waits for the log file to be created; cowrie.json will only be created after the first action (log) is seen
    while not os.path.exists(path):
        log.info("Waiting for log file to be created: %s", path)
        time.sleep(15)

    # detect file rotation, Cowrie rotates its file at 12:00 AM (sorting it by date)
    current_inode = os.stat(path).st_ino # saves current file state
    f = open(path, "r")
    try:
        f.seek(0, 2)  # seek to end to skip historical logs

        while True:
            line = f.readline()
            if line:
                yield line
            else:
                yield None  # idle tick so main loop can check flush timer
                time.sleep(1)
                # only check for rotation when file is idle (no new lines)
                try:
                    if os.stat(path).st_ino != current_inode: # if file state (inode number) changes
                        log.info("Log rotation detected, reopening file.")
                        for lingering_line in f:
                            yield lingering_line
                        f.close()
                        f = open(path, "r")
                        current_inode = os.stat(path).st_ino  # set new inode number
                except FileNotFoundError:
                    log.warning("Log file missing. Waiting for it to reappear: %s", path)
                    f.close()
                    while not os.path.exists(path):
                        time.sleep(5)
                    f = open(path, "r")
                    current_inode = os.stat(path).st_ino
                    log.info("Log file reappeared. Resuming.")
    finally:
        f.close()

# Retries server-side errors given a batch of SQS failure responses
def filter_failed_for_retry(original_batch, failed_messages):
    retryable_ids = {
        failure["Id"]
        for failure in failed_messages
        if not failure.get("SenderFault", False)  # only retry server-side failures
    }
    return [entry for entry in original_batch if entry["Id"] in retryable_ids]

# Sends a batch of logs to SQS 
def send_batch_with_retry(sqs_client, batch, max_retries=3):
    current_batch = batch
    for attempt in range(max_retries + 1): # attempt send for max_retries
        try:
            response = sqs_client.send_message_batch(
                QueueUrl=QUEUE_URL,
                Entries=current_batch
            )
        except Exception as e:
            log.error("Exception sending batch on attempt %d: %s", attempt + 1, e)
            if attempt < max_retries:
                time.sleep(2 ** attempt)
            continue

        failed = response.get("Failed", []) # store failed responses
        if not failed: # if none failed, return
            log.info("Sent %d messages successfully.", len(current_batch))
            return
        # if failed exist, filer for non-senderfault failures and store in buffer and return
        current_batch = filter_failed_for_retry(current_batch, failed)

        # Log sender faults (bad message format, etc.) — these won't be retried
        sender_faults = [f for f in failed if f.get("SenderFault", False)]
        for fault in sender_faults:
            log.error("Sender fault (not retrying) — Id: %s, Code: %s, Message: %s",
                      fault["Id"], fault.get("Code"), fault.get("Message"))

        if not current_batch: # if no more failures remain after filtering sender faults, return
            log.warning("No retryable failures remain after filtering sender faults.")
            return

        log.warning("Attempt %d: %d messages failed, retrying...", attempt + 1, len(current_batch))
        if attempt < max_retries:
            time.sleep(2 ** attempt) # exponential backoff

    log.error("Permanently failed to send %d messages after %d retries: %s",
              len(current_batch), max_retries, [e["Id"] for e in current_batch])


def main():
    if not QUEUE_URL:
        log.error("SQS_QUEUE_URL environment variable is not set. Exiting.")
        return

    if not LOG_PATH:
        log.error("COWRIE_LOG_PATH is not configured. Exiting.")
        return

    # For EC2, boto3 will automatically use the instance's IAM role — no hardcoded credentials needed
    sqs = boto3.client("sqs", region_name=AWS_REGION)

    buffer = []
    last_flush_time = time.monotonic() # keeps a timer for the current program 

    for line in tail_file(LOG_PATH):
        if line is None: # check for flush
            elapsed = time.monotonic() - last_flush_time
            if elapsed >= FLUSH_INTERVAL and buffer:
                send_batch_with_retry(sqs, buffer)
                buffer = []
                last_flush_time = time.monotonic()
            continue

        line = line.strip() # takes the current line and removes any whitespace
        if not line:
            continue

        try:
            log_entry = json.loads(line) # decodes line
            log_entry["honeypot"] = SENSOR_ID
            message_body = json.dumps(log_entry) # encodes line
        except json.JSONDecodeError:
            log.warning("Non-JSON line encountered, wrapping as raw string.")
            message_body = json.dumps({"raw": line, "honeypot": SENSOR_ID})

        # if message is too large, skip and produce log
        if len(message_body.encode("utf-8")) > MAX_SQS_MESSAGE_SIZE:
            log.warning("Skipping oversized message.")
            continue

        # appends the message to the buffer with unique ids
        buffer.append({
            "Id": str(uuid.uuid4()), # unique id generated by uuid.uuid4()
            "MessageBody": message_body
        })

        # size-based flush only — time-based flush is handled by the None branch above
        if len(buffer) >= BATCH_SIZE:
            send_batch_with_retry(sqs, buffer)
            buffer = []
            last_flush_time = time.monotonic()


if __name__ == "__main__":
    main()