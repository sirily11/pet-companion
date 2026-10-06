"use client";

import Image from "next/image";
import { useState } from "react";
import {
  ArrowDown,
  ArrowDownToLine,
  ArrowRight,
  ArrowUpRight,
  Check,
  ChevronDown,
  Coffee,
  Download,
  Github,
  Heart,
  Home,
  Menu,
  MessageCircle,
  Monitor,
  Moon,
  MousePointer2,
  PawPrint,
  Sparkles,
  Sun,
  X,
} from "lucide-react";
import {
  DOWNLOAD_URL,
  GUIDE_URL,
  RELEASES_URL,
  REPOSITORY_URL,
} from "@/lib/links";

const moods = [
  { name: "Happy", text: "Hey, you. You make my day!", icon: Sun },
  { name: "Curious", text: "What are we working on today?", icon: Sparkles },
  { name: "Sleepy", text: "A little break sounds purrfect.", icon: Moon },
];

const questions = [
  {
    title: "What do I need to run PetPaw?",
    answer:
      "A Mac running macOS 14 Sonoma or later. The app supports both Apple Silicon and Intel Macs. Download the DMG, open it, and move PetPaw to your Applications folder.",
  },
  {
    title: "How do I add my first pet?",
    answer:
      "Open PetPaw and choose Import pet companion (⌘I). Select a compatible companion ZIP or folder to add your pet. Your imported pets are saved on your Mac and available the next time you open the app.",
  },
  {
    title: "Do I need an AI key?",
    answer:
      "You can pet, cuddle, play, explore poses, and try the voice demo without a key. Live voice conversations require your own Vercel AI Gateway key with credits, entered in the app’s Settings. Your key is stored securely in macOS Keychain.",
  },
  {
    title: "How do desktop moods work?",
    answer:
      "On macOS 26 or later, a supported Mac with Apple Intelligence enabled can create moods and short thoughts on device. On other Macs, your pet uses local lines and poses. No AI Gateway key is needed for desktop moods.",
  },
  {
    title: "Will my pet stay up to date?",
    answer:
      "PetPaw includes automatic updates through Sparkle. You can also choose Check for Updates from the app menu or download the latest release from GitHub.",
  },
];

function DownloadButton({
  className = "",
  label = "Download for Mac",
}: {
  className?: string;
  label?: string;
}) {
  return (
    <a className={`button button-primary ${className}`} href={DOWNLOAD_URL}>
      <ArrowDownToLine size={19} strokeWidth={1.8} />
      {label}
      <ArrowUpRight className="button-trailing" size={18} />
    </a>
  );
}

export default function HomePage() {
  const [mood, setMood] = useState(0);
  const [petted, setPetted] = useState(false);
  const [dark, setDark] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [activeSection, setActiveSection] = useState("home");
  const selectSection = (section: string) => {
    setActiveSection(section);
    setMenuOpen(false);
  };

  return (
    <div className="site" data-theme={dark ? "dark" : "light"}>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <aside className="navigation-rail" aria-label="Main navigation">
        <a
          className="rail-brand"
          href="#home"
          aria-label="PetPaw home"
          onClick={() => selectSection("home")}
        >
          <PawPrint size={27} />
        </a>
        <nav className="rail-links">
          {[
            { id: "home", label: "Home", icon: Home },
            { id: "features", label: "Explore", icon: Sparkles },
            { id: "download", label: "Get app", icon: Download },
          ].map(({ id, label, icon: Icon }) => (
            <a
              key={id}
              className={`rail-link ${activeSection === id ? "active" : ""}`}
              href={`#${id}`}
              onClick={() => selectSection(id)}
              aria-current={activeSection === id ? "location" : undefined}
            >
              <span className="rail-icon">
                <Icon size={23} strokeWidth={1.7} />
              </span>
              <span>{label}</span>
            </a>
          ))}
        </nav>
        <button
          className="theme-toggle"
          type="button"
          onClick={() => setDark(!dark)}
          aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
        >
          {dark ? <Sun size={22} /> : <Moon size={22} />}
        </button>
      </aside>

      <div className="page-shell">
        <header className="header">
          <a
            className="wordmark"
            href="#home"
            onClick={() => selectSection("home")}
          >
            <PawPrint className="mobile-paw" size={25} />
            <span>
              PetPaw<span className="wordmark-dot">.</span>
            </span>
          </a>
          <span className="header-tagline">
            A little company goes a long way.
          </span>
          <div className="header-actions">
            <a
              className="source-link"
              href={REPOSITORY_URL}
              target="_blank"
              rel="noreferrer"
            >
              <Github size={18} />
              <span>GitHub</span>
              <ArrowUpRight size={14} />
            </a>
            <a className="header-download" href={DOWNLOAD_URL}>
              Get PetPaw
              <ArrowDown size={16} />
            </a>
          </div>
          <button
            className="mobile-menu-toggle"
            type="button"
            aria-label={menuOpen ? "Close navigation" : "Open navigation"}
            aria-expanded={menuOpen}
            aria-controls="mobile-navigation"
            onClick={() => setMenuOpen(!menuOpen)}
          >
            {menuOpen ? <X /> : <Menu />}
          </button>
          {menuOpen && (
            <nav
              id="mobile-navigation"
              className="mobile-navigation"
              aria-label="Mobile navigation"
            >
              <a href="#home" onClick={() => selectSection("home")}>
                Home
              </a>
              <a href="#features" onClick={() => selectSection("features")}>
                Explore
              </a>
              <a href="#download" onClick={() => selectSection("download")}>
                Get the app
              </a>
              <button type="button" onClick={() => setDark(!dark)}>
                {dark ? <Sun size={18} /> : <Moon size={18} />}
                {dark ? "Light theme" : "Dark theme"}
              </button>
            </nav>
          )}
        </header>

        <main id="main">
          <section className="hero" id="home" aria-labelledby="hero-title">
            <div className="hero-copy">
              <div className="eyebrow">
                <span className="status-dot" />
                MADE FOR YOUR MAC. AND YOUR DAY.
              </div>
              <h1 id="hero-title">
                A little pet.
                <br />A lot of{" "}
                <span className="company-word">
                  company
                  <svg viewBox="0 0 440 16" aria-hidden="true">
                    <path d="M4 10C110 1 297 1 435 9" />
                  </svg>
                </span>
                .
              </h1>
              <p className="hero-description">
                Meet your new desktop companion. A playful little pet to hang
                out, chat, and make the everyday a little brighter.
              </p>
              <div className="hero-actions">
                <DownloadButton />
                <a
                  className="text-button"
                  href="#features"
                  onClick={() => selectSection("features")}
                >
                  Meet PetPaw
                  <ArrowRight size={19} />
                </a>
              </div>
              <div className="compatibility">
                <Monitor size={15} />
                <span>
                  macOS 14+<span className="meta-dot">·</span>Apple Silicon &
                  Intel
                </span>
              </div>
            </div>

            <div className="hero-art">
              <div className="art-topline">
                <span>
                  <Sparkles size={15} />
                  SMALL PAWS. BIG PERSONALITY.
                </span>
                <span className="art-dot" />
              </div>
              <div className="pet-stage">
                <div className="pet-orbit" aria-hidden="true" />
                <div className="flower flower-one" aria-hidden="true">
                  ✳
                </div>
                <div className="flower flower-two" aria-hidden="true">
                  ✦
                </div>
                <div className="speech-bubble" role="status" aria-live="polite">
                  {petted
                    ? "Aww, a little love goes a long way!"
                    : moods[mood].text}
                  <Heart size={15} fill="currentColor" />
                </div>
                <button
                  type="button"
                  className={`pet-button ${petted ? "petted" : ""}`}
                  onClick={() => setPetted(!petted)}
                  aria-label={
                    petted
                      ? "Say hello to the kitten again"
                      : "Give the kitten a little love"
                  }
                >
                  <Image
                    className="hero-kitten"
                    src="/images/kitten-hero.webp"
                    alt="A round orange tabby kitten waving a little paw"
                    width={1024}
                    height={1024}
                    priority
                    sizes="(max-width: 700px) 90vw, (max-width: 1100px) 50vw, 580px"
                  />
                  {petted && (
                    <span className="pet-heart" aria-hidden="true">
                      <Heart fill="currentColor" size={35} />
                    </span>
                  )}
                </button>
                <span className="pet-hint">
                  <MousePointer2 size={14} />
                  Psst… give me a little love
                </span>
              </div>
              <div
                className="mood-picker"
                role="group"
                aria-label="Preview your companion’s personality"
              >
                {moods.map(({ name, icon: Icon }, i) => (
                  <button
                    key={name}
                    type="button"
                    className={`mood-chip ${i === mood ? "selected" : ""}`}
                    aria-pressed={i === mood}
                    onClick={() => {
                      setMood(i);
                      setPetted(false);
                    }}
                  >
                    <Icon size={16} />
                    {name}
                    {i === mood && <Check size={14} />}
                  </button>
                ))}
              </div>
            </div>
          </section>

          <div className="intro-strip">
            <span>A companion, in every sense.</span>
            <div>
              <PawPrint size={17} />
              <span>A little playful.</span>
              <Heart size={17} />
              <span>A little thoughtful.</span>
              <Coffee size={17} />
              <span>Always good company.</span>
            </div>
          </div>

          <section
            className="features-section"
            id="features"
            aria-labelledby="features-title"
          >
            <div className="section-heading">
              <div>
                <span className="eyebrow">MORE THAN A CUTE FACE</span>
                <h2 id="features-title">Little moments. Real personality.</h2>
              </div>
              <span className="section-note">
                A friend for the space
                <br />
                between your tabs.
              </span>
            </div>
            <div className="feature-grid">
              <article className="feature-card feature-green">
                <span className="feature-icon">
                  <Monitor size={27} strokeWidth={1.5} />
                </span>
                <span className="feature-number">01</span>
                <h3>
                  Make yourself
                  <br />
                  at home.
                </h3>
                <p>
                  A little companion that lives on your desktop and keeps you
                  company while you do your thing.
                </p>
                <a
                  className="card-footer"
                  href={`${REPOSITORY_URL}#desktop-pet`}
                  target="_blank"
                  rel="noreferrer"
                >
                  <span>Your desktop, a little happier</span>
                  <ArrowUpRight size={21} />
                </a>
              </article>
              <article className="feature-card feature-purple">
                <span className="feature-icon">
                  <MessageCircle size={27} strokeWidth={1.5} />
                </span>
                <span className="feature-number">02</span>
                <h3>
                  A voice.
                  <br />
                  And a personality.
                </h3>
                <p>
                  Talk naturally with your pet. Watch them respond with a voice,
                  expressions, and a mood of their own.
                </p>
                <a
                  className="card-footer"
                  href={`${REPOSITORY_URL}#ai-settings`}
                  target="_blank"
                  rel="noreferrer"
                >
                  <span>Live voice with your AI key</span>
                  <ArrowUpRight size={21} />
                </a>
              </article>
              <article className="feature-card feature-peach">
                <span className="feature-icon">
                  <Heart size={27} strokeWidth={1.5} />
                </span>
                <span className="feature-number">03</span>
                <h3>
                  A little touch
                  <br />
                  of joy.
                </h3>
                <p>
                  Tap to say hello. Stroke to settle in. Hold for a cuddle.
                  Little gestures bring your companion to life.
                </p>
                <a
                  className="card-footer"
                  href={`${REPOSITORY_URL}#interact-with-your-pet`}
                  target="_blank"
                  rel="noreferrer"
                >
                  <span>Go on, give them a cuddle</span>
                  <ArrowUpRight size={21} />
                </a>
              </article>
            </div>
          </section>

          <section className="desktop-section" aria-labelledby="desktop-title">
            <div className="desktop-art">
              <Image
                src="/images/cozy-desktop.webp"
                alt="A sleepy orange kitten resting beside a laptop and a cup of coffee in a soft green workspace"
                width={1536}
                height={1024}
                sizes="(max-width: 800px) 100vw, 55vw"
              />
              <span className="illustration-label">
                <Coffee size={15} />
                The best kind of desk buddy.
              </span>
            </div>
            <div className="desktop-copy">
              <span className="eyebrow">LESS LONELY. MORE LOVELY.</span>
              <h2 id="desktop-title">
                Your day, with
                <br />a little more <span>life.</span>
              </h2>
              <p>
                Deep in a project? Taking five? Your pet is right there with
                you, bringing a little warmth to your workspace.
              </p>
              <ul className="desktop-points">
                <li>
                  <span>
                    <Check size={16} />
                  </span>
                  Stays with you across desktop Spaces
                </li>
                <li>
                  <span>
                    <Check size={16} />
                  </span>
                  Little moods and thoughts throughout the day
                </li>
                <li>
                  <span>
                    <Check size={16} />
                  </span>
                  Move them wherever they feel at home
                </li>
              </ul>
              <a
                className="text-button"
                href={GUIDE_URL}
                target="_blank"
                rel="noreferrer"
              >
                See how it works
                <ArrowUpRight size={18} />
              </a>
            </div>
          </section>

          <section className="getting-started" aria-labelledby="start-title">
            <div className="section-heading">
              <div>
                <span className="eyebrow">HELLO IS ONLY A FEW CLICKS AWAY</span>
                <h2 id="start-title">Bring a little friend home.</h2>
              </div>
              <PawPrint className="heading-paw" size={40} strokeWidth={1.2} />
            </div>
            <div className="steps-grid">
              <article className="step">
                <span className="step-number">1</span>
                <h3>Make room on your Mac.</h3>
                <p>
                  Download PetPaw and move the app into your Applications
                  folder.
                </p>
                <a href={DOWNLOAD_URL}>
                  Download the app
                  <ArrowDownToLine size={16} />
                </a>
              </article>
              <article className="step">
                <span className="step-number">2</span>
                <h3>Meet your first companion.</h3>
                <p>
                  Choose Import pet companion (⌘I) in PetPaw, then select a
                  compatible pet ZIP or folder.
                </p>
                <a href={GUIDE_URL} target="_blank" rel="noreferrer">
                  How to import a pet
                  <ArrowUpRight size={16} />
                </a>
              </article>
              <article className="step">
                <span className="step-number">3</span>
                <h3>Let them settle in.</h3>
                <p>
                  Choose “Show on desktop.” Say hello, give them a cuddle, and
                  get on with your day.
                </p>
                <a href={GUIDE_URL} target="_blank" rel="noreferrer">
                  Read the quick guide
                  <ArrowUpRight size={16} />
                </a>
              </article>
            </div>
          </section>

          <section
            className="download-section"
            id="download"
            aria-labelledby="download-title"
          >
            <div className="download-flower" aria-hidden="true">
              ✳
            </div>
            <div className="download-copy">
              <span className="eyebrow">YOUR DESKTOP’S NEW PLUS ONE</span>
              <h2 id="download-title">
                Good company.
                <br />
                One download away.
              </h2>
              <p>A little personality. A little play. A little PetPaw.</p>
            </div>
            <div className="download-actions">
              <DownloadButton />
              <span>For macOS 14+ · Apple Silicon & Intel</span>
              <a href={RELEASES_URL} target="_blank" rel="noreferrer">
                What’s new on GitHub
                <ArrowUpRight size={14} />
              </a>
            </div>
          </section>

          <section className="faq-section" aria-labelledby="faq-title">
            <div>
              <span className="eyebrow">A FEW LITTLE DETAILS</span>
              <h2 id="faq-title">
                Curious?
                <br /> So are we.
              </h2>
              <p>
                Everything you need to
                <br />
                get your paws on PetPaw.
              </p>
            </div>
            <div className="faq-list">
              {questions.map(({ title, answer }) => (
                <details key={title}>
                  <summary>
                    {title}
                    <ChevronDown size={20} />
                  </summary>
                  <p>{answer}</p>
                </details>
              ))}
            </div>
          </section>
        </main>

        <footer className="footer">
          <a
            className="footer-brand"
            href="#home"
            onClick={() => selectSection("home")}
          >
            <PawPrint size={23} />
            PetPaw<span>.</span>
          </a>
          <span>Made for the little moments.</span>
          <div>
            <a href={REPOSITORY_URL} target="_blank" rel="noreferrer">
              GitHub
              <ArrowUpRight size={14} />
            </a>
            <a href={RELEASES_URL} target="_blank" rel="noreferrer">
              Releases
              <ArrowUpRight size={14} />
            </a>
            <span>© {new Date().getFullYear()} PetPaw</span>
          </div>
        </footer>
      </div>
    </div>
  );
}
