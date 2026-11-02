import asyncio
import html
import hmac
import logging
import os
import re
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from fastapi import APIRouter, Header, Request as FastAPIRequest, status
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

logger = logging.getLogger("tinigsenyas.tts")

tts_api = APIRouter(tags=["Text to Speech"])

_ALLOWED_VOICES = {
    "fil-PH-BlessicaNeural",
    "fil-PH-AngeloNeural",
}
_REGION_PATTERN = re.compile(r"^[a-z0-9-]+$")
_MAX_TEXT_LENGTH = 2000


class SynthesizePayload(BaseModel):
    text: str = Field(..., min_length=1, max_length=_MAX_TEXT_LENGTH)
    voice: str = "fil-PH-BlessicaNeural"
    rate: int = Field(default=0, ge=-50, le=50)


class TtsProviderError(RuntimeError):
    pass


def _is_loopback_origin(origin: Optional[str]) -> bool:
    if not origin:
        return True
    try:
        parsed_origin = urlsplit(origin)
    except ValueError:
        return False
    return (
        parsed_origin.scheme in {"http", "https"}
        and parsed_origin.hostname in {"localhost", "127.0.0.1", "::1"}
        and parsed_origin.username is None
        and parsed_origin.password is None
        and parsed_origin.path in {"", "/"}
        and not parsed_origin.query
        and not parsed_origin.fragment
    )


async def _synthesize_edge_tts_audio(text: str, voice: str, rate: int) -> bytes:
    import edge_tts

    try:
        communicate = edge_tts.Communicate(
            text,
            voice,
            rate=f"{rate:+d}%",
        )
        audio = bytearray()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio.extend(chunk["data"])
        return bytes(audio)
    except (
        edge_tts.exceptions.EdgeTTSException,
        OSError,
        asyncio.TimeoutError,
        TimeoutError,
    ) as error:
        raise TtsProviderError(str(error)) from error


@tts_api.get("/tts/health")
async def tts_health():
    return {"status": "ok"}


@tts_api.post("/tts/synthesize")
async def synthesize_speech(
    request: FastAPIRequest,
    authorization: Optional[str] = Header(None),
    origin: Optional[str] = Header(None),
):
    # Parse body manually / flexibly to support custom error messaging and status codes
    try:
        payload = await request.json()
    except Exception:
        return JSONResponse(status_code=400, content={"error": "Expected a JSON request body."})

    if not isinstance(payload, dict):
        return JSONResponse(status_code=400, content={"error": "Expected a JSON request body."})

    expected_token = os.environ.get("TTS_API_TOKEN", "")
    supplied_token = authorization or ""
    
    # Client IP resolution
    client_ip = request.client.host if request.client else "127.0.0.1"
    is_local_client = (
        client_ip in {"127.0.0.1", "::1"}
        # Behind a reverse proxy the peer address is the proxy itself, so a forwarded
        # request must never inherit the loopback token bypass.
        and not request.headers.get("x-forwarded-for")
        and _is_loopback_origin(origin)
    )

    if not is_local_client:
        if expected_token:
            if not hmac.compare_digest(
                supplied_token,
                f"Bearer {expected_token}",
            ):
                return JSONResponse(status_code=401, content={"error": "Unauthorized TTS request."})
        else:
            allowed_origins = {
                item.strip()
                for item in os.environ.get("TTS_ALLOWED_ORIGINS", "").split(",")
                if item.strip()
            }
            if origin not in allowed_origins:
                return JSONResponse(status_code=401, content={"error": "A TTS access token is required."})

    text = payload.get("text")
    voice = payload.get("voice", "fil-PH-BlessicaNeural")
    rate = payload.get("rate", 0)

    if not isinstance(text, str) or not text.strip():
        return JSONResponse(status_code=400, content={"error": "Text must not be empty."})
    if len(text) > _MAX_TEXT_LENGTH:
        return JSONResponse(status_code=413, content={"error": f"Text must not exceed {_MAX_TEXT_LENGTH} characters."})
    if not isinstance(voice, str) or voice not in _ALLOWED_VOICES:
        return JSONResponse(status_code=400, content={"error": "Unsupported Filipino voice."})
    if isinstance(rate, bool) or not isinstance(rate, int) or not -50 <= rate <= 50:
        return JSONResponse(status_code=400, content={"error": "Rate must be an integer from -50 to 50."})

    speech_key = os.environ.get("AZURE_SPEECH_KEY", "")
    region = os.environ.get("AZURE_SPEECH_REGION", "")

    if not speech_key or not _REGION_PATTERN.fullmatch(region):
        try:
            audio = await _synthesize_edge_tts_audio(text, voice, rate)
        except TtsProviderError as error:
            logger.warning("Microsoft Edge TTS request failed: %s", error)
            return JSONResponse(status_code=502, content={"error": "The speech provider is currently unavailable."})
        if not audio:
            return JSONResponse(status_code=502, content={"error": "The speech provider returned empty audio."})
        return Response(
            content=audio,
            media_type="audio/mpeg",
            headers={"Cache-Control": "no-store"},
        )

    ssml = (
        '<speak version="1.0" xml:lang="fil-PH">'
        f'<voice name="{voice}"><prosody rate="{rate}%">'
        f"{html.escape(text)}"
        "</prosody></voice></speak>"
    )
    upstream = Request(
        f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
        data=ssml.encode("utf-8"),
        headers={
            "Ocp-Apim-Subscription-Key": speech_key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
        },
        method="POST",
    )

    try:
        with urlopen(upstream, timeout=20) as response:
            audio = response.read()
    except HTTPError as error:
        logger.warning("Azure Speech returned HTTP %s", error.code)
        return JSONResponse(status_code=502, content={"error": "The speech provider rejected the request."})
    except (URLError, TimeoutError) as error:
        logger.warning("Azure Speech request failed: %s", error)
        return JSONResponse(status_code=502, content={"error": "The speech provider is currently unavailable."})

    if not audio:
        return JSONResponse(status_code=502, content={"error": "The speech provider returned empty audio."})
    return Response(content=audio, media_type="audio/mpeg", headers={"Cache-Control": "no-store"})
