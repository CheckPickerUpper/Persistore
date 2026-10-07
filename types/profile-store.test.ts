import ProfileStore = require("..");

const store = ProfileStore.New<{ Coins: number }, { Region: string }>("Types", { Coins: 0 });
const result = store.StartSessionResultAsync("Player", { Cancel: () => true });

// @ts-expect-error A failed claim has no Profile.
result.Profile;

switch (result.Kind) {
	case "SessionStarted": {
		const profile = result.Profile;
		const sameStore: ProfileStore.Store<{ Coins: number }, { Region: string }> = profile.ProfileStore;
		const outcome: ProfileStore.SaveAttemptOutcome | "SessionEnded" = profile.SaveAsync();
		const connection: ProfileStore.Connection = profile.OnSessionEnd.Connect((reason) => {
			const ended: ProfileStore.SessionEndReason = reason;
		});
		profile.OnSessionEnd.Connect(() => {});
		profile.MessageHandler((message: ProfileStore.JSONAcceptable, processed) => processed());
		// @ts-expect-error The caller cannot choose the incoming message type.
		profile.MessageHandler<{ Coins: number }>((message, processed) => processed());
		break;
	}
	case "SessionNotStarted": {
		const reason: ProfileStore.SessionNotStartedReason = result.Because;
		break;
	}
	default:
		result satisfies never;
}

// @ts-expect-error The reason vocabulary is closed.
const invalidReason: ProfileStore.SessionNotStartedReason = "Unknown";

const mockResult: ProfileStore.SessionStartResult<{ Coins: number }, { Region: string }> =
	store.Mock.StartSessionResultAsync("Mock", { Steal: true, Cancel: () => false });
store.OnSaveAttempt.Connect((key, outcome, purpose) => {
	const saved: ProfileStore.SaveAttemptOutcome = outcome;
});
store.Mock.OnSaveAttempt.Connect(() => {});
const upstreamProfile: ProfileStore.Profile<{ Coins: number }, { Region: string }> = store.StartSessionAsync("Upstream");

ProfileStore.IsClosing = false;
ProfileStore.IsCriticalState = false;
ProfileStore.DataStoreState = "NoAccess";

if (ProfileStore.IsClosing === false) {
	store.StartSessionResultAsync("Yielding");
	const narrowed = ProfileStore.IsClosing;
	// @ts-expect-error A narrowed false value cannot be assigned true after the call.
	const changed: typeof narrowed = true;
}
