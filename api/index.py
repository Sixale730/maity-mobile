"""
Maity Backend API - FastAPI Application

Main entry point for Vercel serverless functions.
Processes conversations with OpenAI and stores in Firebase.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .routers import (
    conversations_router,
    metrics_router,
    action_items_router,
    omi_router,
    voice_profiles_router,
    communication_router,
    messages_router,
)

# Create FastAPI app
app = FastAPI(
    title="Maity API",
    description="Backend API for Maity - Conversation categorization and metrics",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify your app's domain
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(conversations_router)
app.include_router(metrics_router)
app.include_router(action_items_router)
app.include_router(omi_router)
app.include_router(voice_profiles_router)
app.include_router(communication_router)
app.include_router(messages_router)


@app.get("/")
async def root():
    """Health check endpoint"""
    return {
        "status": "ok",
        "service": "Maity API",
        "version": "1.0.0",
    }


@app.get("/health")
async def health():
    """Health check for monitoring"""
    return {"status": "healthy"}


# Vercel requires the app to be exposed at module level
# The handler is automatically picked up by Vercel
