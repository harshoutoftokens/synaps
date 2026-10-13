'use client';

import { Sidebar } from '@/components/Sidebar';
import { MediaViewer } from '@/components/MediaViewer';
import { TokenPrompt } from '@/components/TokenPrompt';

export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen relative">
      <Sidebar />
      <MediaViewer />
      <TokenPrompt />
      <main
        className="min-h-screen transition-all duration-300 ease-out lg:ml-[calc(var(--sidebar-width)+16px)]"
      >
        {children}
      </main>
    </div>
  );
}
