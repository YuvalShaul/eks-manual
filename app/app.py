import os
import socket

from flask import Flask

app = Flask(__name__)


@app.route("/")
def hello():
    return {
        "message": "Hello from EKS!",
        "pod": socket.gethostname(),
        "version": os.environ.get("VERSION", "dev"),
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
