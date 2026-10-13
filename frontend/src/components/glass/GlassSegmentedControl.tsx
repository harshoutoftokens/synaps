'use client';

import { motion } from 'framer-motion';
import { useState, useRef, useEffect } from 'react';

interface SegmentOption {
  key: string;
  label: string;
}

interface GlassSegmentedControlProps {
  options: SegmentOption[];
  value: string;
  onChange: (key: string) => void;
  className?: string;
}

export function GlassSegmentedControl({
  options,
  value,
  onChange,
  className = '',
}: GlassSegmentedControlProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [indicatorStyle, setIndicatorStyle] = useState({ left: 0, width: 0 });

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const measure = () => {
      const activeIndex = options.findIndex((o) => o.key === value);
      const items = container.querySelectorAll('[data-segment-item]');
      if (items[activeIndex]) {
        const el = items[activeIndex] as HTMLElement;
        setIndicatorStyle({
          left: el.offsetLeft,
          width: el.offsetWidth,
        });
      }
    };
    measure();
    // Re-measure when the control changes size (breakpoint switch, late font load)
    const observer = new ResizeObserver(measure);
    observer.observe(container);
    return () => observer.disconnect();
  }, [value, options]);

  return (
    <div
      ref={containerRef}
      className={`segmented-control relative ${className}`}
    >
      {/* Sliding indicator */}
      {/* No layoutId: TopBar mounts two of these (desktop + mobile) at once, and a shared
          layoutId makes framer-motion animate the indicator between them */}
      <motion.div
        className="segmented-control-indicator"
        animate={{
          left: indicatorStyle.left,
          width: indicatorStyle.width,
        }}
        transition={{ type: 'spring', stiffness: 350, damping: 30 }}
        style={{
          top: 3,
          bottom: 3,
        }}
      />

      {options.map((option) => (
        <button
          key={option.key}
          data-segment-item
          data-active={value === option.key ? 'true' : 'false'}
          aria-pressed={value === option.key}
          className="segmented-control-item"
          onClick={() => onChange(option.key)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
