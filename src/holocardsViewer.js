export function openHolocardsViewer(src, name = "Character", description = "", onCloseCallback) {
    let overlay = document.getElementById('holocards-overlay');
    
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'holocards-overlay';
        overlay.className = 'holocards-overlay';
        overlay.innerHTML = `
            <div class="holo-card-container" id="holo-card">
                <div class="holo-card-inner">
                    <div class="holo-card-face holo-card-front">
                        <div class="holo-card">
                            <div class="holo-card-bg-img" style="background-image: url('${src}');"></div>
                            <div class="holo-card-pattern"></div>
                            <div class="holo-card-sheen"></div>
                            <div class="holo-card-border"></div>
                            <div class="holo-card-gradient"></div>
                            <div class="holo-card-info">
                                <h2 class="holo-card-name">${name}</h2>
                                <div class="holo-card-meta">
                                    <!-- <span class="holo-card-class">ULTRA RARE</span> -->
                                </div>
                                <!-- <div class="holo-card-author">theAuthor</div> -->
                            </div>
                        </div>
                        <div class="holo-overlay-layer">
                            <div class="holo-shard holo-shard-1"></div>
                            <div class="holo-shard holo-shard-2"></div>
                            <div class="holo-shard holo-shard-3"></div>
                            <div class="holo-shard holo-shard-4"></div>
                        </div>
                        <div class="holo-card-top-badge">
                            <span>SC</span>
                        </div>
                        <div class="holo-glare"></div>
                        <div class="holo-casing"></div>
                    </div>
                    <div class="holo-card-face holo-card-back">
                        <h2 style="border-bottom: 1px solid var(--holo-accent-green); padding-bottom: 10px; margin-bottom: 10px;">${name}</h2>
                        <div style="font-size: 14px; line-height: 1.5; color: #eee; overflow-y: auto; flex-grow: 1;">
                            ${description || "No description available."}
                        </div>
                    </div>
                </div>
            </div>
            <div id="holocards-close-btn" style="position: absolute; top: calc(20px + env(safe-area-inset-top)); right: 20px; z-index: 20020; padding: 10px; cursor: pointer; background: rgba(0,0,0,0.5); border-radius: 50%;">
                <svg viewBox="0 0 24 24" style="width:24px;height:24px;fill:white;"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
            </div>
        `;
        document.body.appendChild(overlay);

        const card = overlay.querySelector('#holo-card');
        const closeBtn = overlay.querySelector('#holocards-close-btn');
        const bgImage = overlay.querySelector('.holo-card-bg-img');
        const cardInfo = overlay.querySelector('.holo-card-info');
        const topBadge = overlay.querySelector('.holo-card-top-badge');
        const fullSheen = overlay.querySelector('.holo-card-sheen');
        const holoPattern = overlay.querySelector('.holo-card-pattern');
        const overlayLayer = overlay.querySelector('.holo-overlay-layer');
        const glare = overlay.querySelector('.holo-glare');

        // Logic
        const maxTilt = 10;

        const updateCardTilt = (xNorm, yNorm) => {
            const rotateY = xNorm * maxTilt * 2; 
            const rotateX = -yNorm * maxTilt * 2;

            card.style.transform = `rotateX(${rotateX}deg) rotateY(${rotateY}deg)`;

            const parallaxX = xNorm * 5;
            const parallaxY = yNorm * 5;
            bgImage.style.transform = `scale(1.1) translateX(${parallaxX}px) translateY(${parallaxY}px)`;

            const textParallaxX = xNorm * 10;
            const textParallaxY = yNorm * 10;
            cardInfo.style.transform = `translateX(${textParallaxX}px) translateY(${textParallaxY}px)`;
            if (topBadge) {
                topBadge.style.transform = `translateX(${textParallaxX}px) translateY(${textParallaxY}px)`;
            }

            const sheenAngle = 115;
            const sheenPos = 50 + (xNorm * 40);
            const stop1 = sheenPos - 15;
            const stop2 = sheenPos;
            const stop3 = sheenPos + 15;

            const gradient = `linear-gradient(${sheenAngle}deg, transparent ${stop1}%, rgba(255,255,255,0.1) ${stop2}%, transparent ${stop3}%)`;
            const maskGradient = `linear-gradient(${sheenAngle}deg, transparent ${stop1}%, black ${stop2}%, transparent ${stop3}%)`;

            fullSheen.style.background = gradient;
            holoPattern.style.webkitMaskImage = maskGradient;
            holoPattern.style.maskImage = maskGradient;
            overlayLayer.style.webkitMaskImage = maskGradient;
            overlayLayer.style.maskImage = maskGradient;
            
            glare.style.opacity = Math.min(1, Math.abs(xNorm) + Math.abs(yNorm) * 0.5);
        };

        const resetTilt = () => {
            card.style.transform = 'rotateX(0deg) rotateY(0deg)';
            bgImage.style.transform = `scale(1.1)`;
            cardInfo.style.transform = `translateX(0) translateY(0)`;
            if (topBadge) topBadge.style.transform = `translateX(0) translateY(0)`;
            fullSheen.style.background = `linear-gradient(120deg, transparent 35%, rgba(255,255,255,0.1) 50%, transparent 65%)`;
            overlayLayer.style.webkitMaskImage = `linear-gradient(120deg, transparent, transparent)`;
            glare.style.opacity = '0';
        };

        // Mouse Events
        const onMouseMove = (e) => {
            const xNorm = (e.clientX / window.innerWidth - 0.5) * 2;
            const yNorm = (e.clientY / window.innerHeight - 0.5) * 2;
            updateCardTilt(xNorm, yNorm);
        };

        // Touch Events
        let lastGamma = 0;
        let lastBeta = 0;
        let calGamma = 0;
        let calBeta = 60;

        const updateGyroTilt = () => {
            let tiltX = lastGamma - calGamma; 
            let tiltY = lastBeta - calBeta;
            if (tiltX > 30) tiltX = 30; if (tiltX < -30) tiltX = -30;
            if (tiltY > 30) tiltY = 30; if (tiltY < -30) tiltY = -30;
            updateCardTilt(tiltX / 30, -tiltY / 30);
        };

        const onDeviceOrientation = (e) => {
            if (e.gamma === null) return;
            lastGamma = e.gamma;
            lastBeta = e.beta;
            updateGyroTilt();
        };

        const onTouchStart = () => {
            calGamma = lastGamma;
            calBeta = lastBeta;
            updateGyroTilt();
        };

        // Close Logic
        const closeViewer = () => {
            overlay.classList.remove('visible');
            window.removeEventListener('mousemove', onMouseMove);
            window.removeEventListener('deviceorientation', onDeviceOrientation);
            window.removeEventListener('touchstart', onTouchStart);
            setTimeout(() => {
                overlay.style.display = 'none';
                resetTilt();
                card.classList.remove('flipped');
                if (overlay._onCloseCallback) overlay._onCloseCallback();
            }, 300);
        };

        closeBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            closeViewer();
        });

        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) closeViewer();
        });

        card.addEventListener('click', (e) => {
            e.stopPropagation();
            calGamma = lastGamma;
            calBeta = lastBeta;
            updateGyroTilt();
        });

        overlay._closeViewer = closeViewer;
        overlay._onMouseMove = onMouseMove;
        overlay._onDeviceOrientation = onDeviceOrientation;
        overlay._onTouchStart = onTouchStart;
        overlay._updateCardTilt = updateCardTilt;
    } else {
        // Update existing
        overlay.querySelector('.holo-card-bg-img').style.backgroundImage = `url('${src}')`;
        overlay.querySelector('.holo-card-name').textContent = name;
        overlay.querySelector('.holo-card-back h2').textContent = name;
        overlay.querySelector('.holo-card-back div').textContent = description || "No description available.";
    }

    overlay._onCloseCallback = onCloseCallback;
    overlay.style.display = 'flex';
    
    window.addEventListener('mousemove', overlay._onMouseMove);
    window.addEventListener('deviceorientation', overlay._onDeviceOrientation);
    window.addEventListener('touchstart', overlay._onTouchStart);

    // Initialize tilt to show effects immediately
    if (overlay._updateCardTilt) {
        overlay._updateCardTilt(0, 0);
    }

    requestAnimationFrame(() => {
        overlay.classList.add('visible');
    });
}