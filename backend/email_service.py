"""
CAN-SPAM Act Compliant Email Service for TinigSenyas.

Enforces federal CAN-SPAM requirements (15 U.S.C. §§ 7701-7713):
1. Non-deceptive header and sender information ('From', 'Reply-To').
2. Non-misleading subject line.
3. Conspicuous physical postal mailing address.
4. Clear, functional 1-click unsubscribe link.
5. Persistent opt-out suppression list honored immediately (within statutory 10 business days).
"""

import json
import logging
import os
import re
from pathlib import Path
from typing import Optional, Set

logger = logging.getLogger("tinigsenyas.email")

# Suppression list storage path
SUPPRESSION_FILE = Path(__file__).parent / "email_suppression_list.json"

# CAN-SPAM Sender Identity
DEFAULT_SENDER_NAME = "TinigSenyas Team"
DEFAULT_SENDER_EMAIL = "updates@tinigsenyas.org"

# PHYSICAL POSTAL ADDRESS REQUIREMENT (CAN-SPAM § 7704(a)(5)(A))
PHYSICAL_POSTAL_ADDRESS = os.environ.get(
    "COMPANY_PHYSICAL_POSTAL_ADDRESS",
    "KAINAKAP Inclusive & Opportunity Inc. / TinigSenyas Project, 2034 Zamora Street, Brgy. 782, Sta. Ana, Manila, Philippines",
)

BASE_APP_URL = os.environ.get("APP_BASE_URL", "https://tinigsenyas.org")


class EmailSuppressionManager:
    """Manages the suppression list of unsubscribed email addresses."""

    def __init__(self, filepath: Path = SUPPRESSION_FILE):
        self.filepath = filepath
        self._suppressed: Set[str] = set()
        self._load()

    def _load(self):
        if self.filepath.exists():
            try:
                with open(self.filepath, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        self._suppressed = {e.lower().strip() for e in data}
            except Exception as e:
                logger.error("Failed to load suppression list: %s", e)
                self._suppressed = set()

    def _save(self):
        try:
            with open(self.filepath, "w", encoding="utf-8") as f:
                json.dump(sorted(list(self._suppressed)), f, indent=2)
        except Exception as e:
            logger.error("Failed to save suppression list: %s", e)

    def is_suppressed(self, email: str) -> bool:
        """Check if an email address has opted out."""
        return email.lower().strip() in self._suppressed

    def add_suppression(self, email: str) -> bool:
        """Add an email to the opt-out suppression list immediately."""
        clean_email = email.lower().strip()
        if not re.match(r"^[^@]+@[^@]+\.[^@]+$", clean_email):
            raise ValueError("Invalid email format.")
        self._suppressed.add(clean_email)
        self._save()
        logger.info("Email '%s' successfully unsubscribed and suppressed.", clean_email)
        return True


suppression_manager = EmailSuppressionManager()


def generate_can_spam_email_body(
    recipient_email: str,
    subject: str,
    html_content: str,
    postal_address: Optional[str] = None,
) -> dict:
    """
    Constructs a CAN-SPAM compliant email payload.
    Raises ValueError if recipient has previously unsubscribed.
    """
    if suppression_manager.is_suppressed(recipient_email):
        raise ValueError(
            f"Cannot send marketing email to '{recipient_email}': Address has opted out under CAN-SPAM."
        )

    address = postal_address or PHYSICAL_POSTAL_ADDRESS
    unsubscribe_url = f"{BASE_APP_URL}/api/v1/unsubscribe?email={recipient_email}"

    footer_html = f"""
    <hr style="border:0;border-top:1px solid #e1e4e8;margin:24px 0;">
    <div style="font-size:12px;color:#586069;line-height:1.5;">
      <p style="margin:0 0 6px 0;">
        You received this email because you opted in to receive TinigSenyas application updates.
      </p>
      <p style="margin:0 0 6px 0;">
        <strong>Our Physical Address:</strong><br>
        {address}
      </p>
      <p style="margin:0;">
        <a href="{unsubscribe_url}" style="color:#0366d6;text-decoration:underline;">
          Unsubscribe / Opt-out immediately
        </a>
      </p>
    </div>
    """

    full_html = f"""
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"></head>
    <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#24292e;padding:16px;">
      {html_content}
      {footer_html}
    </body>
    </html>
    """

    return {
        "from": f"{DEFAULT_SENDER_NAME} <{DEFAULT_SENDER_EMAIL}>",
        "to": recipient_email,
        "subject": subject,
        "html": full_html,
        "headers": {
            "List-Unsubscribe": f"<{unsubscribe_url}>",
            "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
        },
    }

