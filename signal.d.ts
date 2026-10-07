// TypeScript declarations adapted from @rbxts/profile-store 1.0.3 by quamatic.
// https://github.com/Quamatic/rbxts-profile-store — Apache-2.0; see LICENSE.
// Modified for the CheckPickerUpper/ProfileStore fork.

export interface Connection {
	Disconnect(): void;
}

export interface Signal<T extends unknown[] = []> {
	Connect(listener: (...parameters: T) => void): Connection;
	GetListenerCount(): number;
	Wait(): LuaTuple<T>;
}
