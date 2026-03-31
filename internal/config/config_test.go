package config

import "testing"

func TestValidateOpenCodeDownloadURL(t *testing.T) {
	tests := []struct {
		name    string
		url     string
		wantErr bool
	}{
		{
			name:    "official github release",
			url:     "https://github.com/anomalyco/opencode/releases/download/v1.2.3/opencode-linux-amd64",
			wantErr: false,
		},
		{
			name:    "wrong host",
			url:     "https://example.com/anomalyco/opencode/releases/download/v1.2.3/opencode-linux-amd64",
			wantErr: true,
		},
		{
			name:    "wrong path",
			url:     "https://github.com/anomalyco/opencode/archive/v1.2.3.tar.gz",
			wantErr: true,
		},
		{
			name:    "query string not allowed",
			url:     "https://github.com/anomalyco/opencode/releases/download/v1.2.3/opencode-linux-amd64?download=1",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateOpenCodeDownloadURL(tt.url)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateOpenCodeDownloadURL(%q) error = %v, wantErr %v", tt.url, err, tt.wantErr)
			}
		})
	}
}

func TestParseSourceRepo(t *testing.T) {
	tests := []struct {
		name     string
		repo     string
		wantHost string
		wantSSH  bool
		wantErr  bool
	}{
		{
			name:     "https github repo",
			repo:     "https://github.com/addiberra/multipass-devenv.git",
			wantHost: "github.com",
			wantSSH:  false,
		},
		{
			name:     "scp style github ssh repo",
			repo:     "git@github.com:addiberra/multipass-devenv.git",
			wantHost: "github.com",
			wantSSH:  true,
		},
		{
			name:     "ssh url gitlab repo",
			repo:     "ssh://git@gitlab.com/group/project.git",
			wantHost: "gitlab.com",
			wantSSH:  true,
		},
		{
			name:    "unsupported ssh host",
			repo:    "git@example.com:org/repo.git",
			wantErr: true,
		},
		{
			name:    "wrong ssh user",
			repo:    "ssh://ubuntu@github.com/org/repo.git",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			repo, err := ParseSourceRepo(tt.repo)
			if (err != nil) != tt.wantErr {
				t.Fatalf("ParseSourceRepo(%q) error = %v, wantErr %v", tt.repo, err, tt.wantErr)
			}
			if tt.wantErr {
				return
			}
			if repo.Host != tt.wantHost || repo.UsesSSH != tt.wantSSH {
				t.Fatalf("ParseSourceRepo(%q) = %+v, want host=%q ssh=%v", tt.repo, repo, tt.wantHost, tt.wantSSH)
			}
		})
	}
}
